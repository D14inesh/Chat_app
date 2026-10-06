"""Edit history and chat lock.

Edit history: every earlier version of an edited message, still encrypted
with the chat's key (the apps decrypt it), visible to the chat's members.

Chat lock: one PIN per account (bcrypt-hashed here) hides chats behind a
"Locked chats" folder on every device. Which chats are locked is per
person, like muting."""
import time

import bcrypt
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.database import execute, one, query
from app.core.security import require_auth

router = APIRouter()

MAX_TRIES = 5
WINDOW_S = 300
_tries: dict[str, list[float]] = {}


# ── Edit history ─────────────────────────────────────────────

@router.get("/api/messages/{message_id}/edits")
async def edit_history(message_id: str, user_id: str = Depends(require_auth)):
    msg = await one(
        """SELECT m.id, m.ciphertext, m.iv, m.edited_at, m.created_at FROM messages m
             JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $2
            WHERE m.id = $1 AND m.deleted_at IS NULL""",
        message_id, user_id,
    )
    if not msg:
        raise HTTPException(404, "Message not found.")
    rows = await query(
        "SELECT ciphertext, iv, written_at FROM message_edits WHERE message_id = $1 ORDER BY written_at",
        message_id,
    )
    versions = [{"ciphertext": r["ciphertext"], "iv": r["iv"], "at": r["written_at"]} for r in rows]
    versions.append({"ciphertext": msg["ciphertext"], "iv": msg["iv"], "at": msg["edited_at"] or msg["created_at"], "current": True})
    return {"versions": versions}


# ── Chat lock ────────────────────────────────────────────────

def _valid_pin(pin) -> str:
    pin = str(pin or "")
    if not pin.isdigit() or not 4 <= len(pin) <= 8:
        raise HTTPException(400, "The PIN must be 4–8 digits.")
    return pin


async def _check_pin(user_id: str, pin) -> None:
    now = time.time()
    recent = [t for t in _tries.get(user_id, []) if now - t < WINDOW_S]
    if len(recent) >= MAX_TRIES:
        raise HTTPException(429, "Too many wrong PINs — try again in a few minutes.")
    row = await one("SELECT chat_lock_pin_hash FROM users WHERE id = $1", user_id)
    if not row or not row["chat_lock_pin_hash"]:
        raise HTTPException(400, "Set a chat lock PIN first.")
    if not bcrypt.checkpw(str(pin or "").encode(), row["chat_lock_pin_hash"].encode()):
        recent.append(now)
        _tries[user_id] = recent
        left = MAX_TRIES - len(recent)
        raise HTTPException(403, f"Wrong PIN. {left} tr{'y' if left == 1 else 'ies'} left." if left else "Wrong PIN.")
    _tries.pop(user_id, None)


@router.get("/api/chat-lock")
async def lock_status(user_id: str = Depends(require_auth)):
    row = await one("SELECT chat_lock_pin_hash IS NOT NULL AS has_pin FROM users WHERE id = $1", user_id)
    return {"hasPin": bool(row and row["has_pin"])}


@router.post("/api/chat-lock/pin")
async def set_pin(request: Request, user_id: str = Depends(require_auth)):
    """Set the PIN, or change it (the current PIN is needed then)."""
    body = await request.json()
    pin = _valid_pin(body.get("pin"))
    row = await one("SELECT chat_lock_pin_hash FROM users WHERE id = $1", user_id)
    if row and row["chat_lock_pin_hash"]:
        await _check_pin(user_id, body.get("currentPin"))
    await execute("UPDATE users SET chat_lock_pin_hash = $2 WHERE id = $1", user_id,
                  bcrypt.hashpw(pin.encode(), bcrypt.gensalt(10)).decode())
    return {"hasPin": True}


@router.post("/api/chat-lock/verify")
async def verify_pin(request: Request, user_id: str = Depends(require_auth)):
    await _check_pin(user_id, (await request.json()).get("pin"))
    return {"ok": True}


@router.delete("/api/chat-lock/pin")
async def remove_pin(request: Request, user_id: str = Depends(require_auth)):
    """Turns chat lock off: the PIN goes and every locked chat is unlocked."""
    await _check_pin(user_id, (await request.json()).get("pin"))
    await execute("UPDATE users SET chat_lock_pin_hash = NULL WHERE id = $1", user_id)
    await execute("UPDATE conversation_members SET locked = false WHERE user_id = $1", user_id)
    await execute("UPDATE users SET private_lock = false WHERE id = $1", user_id)
    return {"hasPin": False}


@router.get("/api/chat-lock/private")
async def private_status(user_id: str = Depends(require_auth)):
    row = await one("SELECT private_lock, chat_lock_pin_hash IS NOT NULL AS has_pin FROM users WHERE id = $1", user_id)
    return {"enabled": bool(row["private_lock"]), "hasPin": bool(row["has_pin"])}


@router.patch("/api/chat-lock/private")
async def set_private(request: Request, user_id: str = Depends(require_auth)):
    """All 1-to-1 chats behind the PIN. Turning it off needs the PIN."""
    body = await request.json()
    enabled = bool(body.get("enabled"))
    has = await one("SELECT chat_lock_pin_hash IS NOT NULL AS ok FROM users WHERE id = $1", user_id)
    if not has["ok"]:
        raise HTTPException(400, "Set a chat lock PIN first.")
    if not enabled:
        await _check_pin(user_id, body.get("pin"))
    await execute("UPDATE users SET private_lock = $2 WHERE id = $1", user_id, enabled)
    return {"enabled": enabled}


@router.patch("/api/conversations/{conversation_id}/lock")
async def set_locked(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    locked = bool(body.get("locked"))
    has = await one("SELECT chat_lock_pin_hash IS NOT NULL AS ok FROM users WHERE id = $1", user_id)
    if not has["ok"]:
        raise HTTPException(400, "Set a chat lock PIN first.")
    if not locked:
        # Taking a chat out of the locked folder needs the PIN.
        await _check_pin(user_id, body.get("pin"))
    row = await one(
        "UPDATE conversation_members SET locked = $3 WHERE conversation_id = $1 AND user_id = $2 RETURNING locked",
        conversation_id, user_id, locked,
    )
    if not row:
        raise HTTPException(404, "Not your conversation.")
    return {"locked": row["locked"]}
