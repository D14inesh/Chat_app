"""Business tools: product catalogue, away auto-reply, private customer notes.

Catalogue photos are public product pictures (stored plain, like profile
photos). Products shared into a chat travel as an encrypted 'product'
message. The away message is plain text the business wrote for anyone who
messages it, so the server can send it while the business is offline."""
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse

from app.core.config import STORAGE_DIR
from app.core.database import execute, one, query
from app.core.security import require_auth

router = APIRouter()

CATALOG_DIR = Path(STORAGE_DIR) / "catalog"
CATALOG_DIR.mkdir(parents=True, exist_ok=True)
PHOTO_EXT = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
MAX_PHOTO = 6 * 1024 * 1024
MAX_ITEMS = 100


def _shape(r: dict) -> dict:
    return {
        "id": r["id"], "sellerId": r["user_id"], "name": r["name"],
        "price": float(r["price"]) if r["price"] is not None else None, "currency": r["currency"],
        "description": r["description"], "available": r["available"], "position": r["position"],
        "photoUrl": f"/api/catalog/{r['id']}/photo" if r["photo_path"] else None,
    }


def _price(raw) -> Decimal | None:
    s = str(raw or "").strip().replace(",", "")
    if not s:
        return None
    try:
        v = Decimal(s)
    except InvalidOperation:
        raise HTTPException(400, "Enter the price as a number, like 499 or 12.50.")
    if v < 0 or v > Decimal("9999999999"):
        raise HTTPException(400, "That price is out of range.")
    return v.quantize(Decimal("0.01"))


async def _save_photo(photo: UploadFile | None) -> str | None:
    if photo is None or not photo.filename:
        return None
    ext = PHOTO_EXT.get(photo.content_type or "")
    if not ext:
        raise HTTPException(400, "The photo must be a JPG, PNG or WebP image.")
    data = await photo.read()
    if len(data) > MAX_PHOTO:
        raise HTTPException(400, "That photo is too big (6 MB max).")
    name = f"{uuid.uuid4().hex}{ext}"
    (CATALOG_DIR / name).write_bytes(data)
    return name


# ── Catalogue ────────────────────────────────────────────────

@router.get("/api/users/{user_id}/catalog")
async def get_catalog(user_id: str, me: str = Depends(require_auth)):
    rows = await query(
        """SELECT * FROM catalog_items WHERE user_id = $1 AND (available OR user_id = $2)
            ORDER BY position, created_at""",
        user_id, me,
    )
    return {"items": [_shape(r) for r in rows]}


@router.post("/api/catalog", status_code=201)
async def add_item(
    name: str = Form(...), price: str = Form(""), currency: str = Form("INR"), description: str = Form(""),
    available: str = Form("true"), photo: UploadFile | None = File(None), user_id: str = Depends(require_auth),
):
    name = name.strip()[:80]
    if not name:
        raise HTTPException(400, "Give the product a name.")
    count = await one("SELECT count(*) AS n, coalesce(max(position), -1) AS last FROM catalog_items WHERE user_id = $1", user_id)
    if count["n"] >= MAX_ITEMS:
        raise HTTPException(400, f"A catalogue holds up to {MAX_ITEMS} products.")
    row = await one(
        """INSERT INTO catalog_items (user_id, name, price, currency, description, available, photo_path, position)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *""",
        user_id, name, _price(price), (currency or "INR").strip().upper()[:3], description.strip()[:600],
        available.lower() != "false", await _save_photo(photo), count["last"] + 1,
    )
    return {"item": _shape(row)}


@router.patch("/api/catalog/{item_id}")
async def edit_item(
    item_id: str, name: str = Form(...), price: str = Form(""), currency: str = Form("INR"),
    description: str = Form(""), available: str = Form("true"), remove_photo: str = Form("false"),
    photo: UploadFile | None = File(None), user_id: str = Depends(require_auth),
):
    old = await one("SELECT photo_path FROM catalog_items WHERE id = $1 AND user_id = $2", item_id, user_id)
    if not old:
        raise HTTPException(404, "No such product.")
    new_photo = await _save_photo(photo)
    keep = old["photo_path"] if remove_photo.lower() != "true" else None
    if (new_photo or keep is None) and old["photo_path"]:
        (CATALOG_DIR / old["photo_path"]).unlink(missing_ok=True)
    row = await one(
        """UPDATE catalog_items SET name = $3, price = $4, currency = $5, description = $6, available = $7, photo_path = $8
            WHERE id = $1 AND user_id = $2 RETURNING *""",
        item_id, user_id, name.strip()[:80] or "Product", _price(price), (currency or "INR").strip().upper()[:3],
        description.strip()[:600], available.lower() != "false", new_photo or keep,
    )
    return {"item": _shape(row)}


@router.delete("/api/catalog/{item_id}")
async def delete_item(item_id: str, user_id: str = Depends(require_auth)):
    row = await one("DELETE FROM catalog_items WHERE id = $1 AND user_id = $2 RETURNING photo_path", item_id, user_id)
    if row and row["photo_path"]:
        (CATALOG_DIR / row["photo_path"]).unlink(missing_ok=True)
    return {"ok": True}


@router.post("/api/catalog/reorder")
async def reorder(request: Request, user_id: str = Depends(require_auth)):
    ids = (await request.json()).get("ids") or []
    for i, item_id in enumerate(ids[:MAX_ITEMS]):
        await execute("UPDATE catalog_items SET position = $3 WHERE id = $1 AND user_id = $2", item_id, user_id, i)
    return {"ok": True}


@router.get("/api/catalog/{item_id}/photo")
async def item_photo(item_id: str, _: str = Depends(require_auth)):
    row = await one("SELECT photo_path FROM catalog_items WHERE id = $1", item_id)
    if not row or not row["photo_path"]:
        raise HTTPException(404, "No photo.")
    return FileResponse(CATALOG_DIR / row["photo_path"], headers={"Cache-Control": "private, max-age=86400"})


# ── Away message ─────────────────────────────────────────────

def _hhmm(v, default: str) -> str:
    s = str(v or default)
    try:
        h, m = (int(x) for x in s.split(":"))
        if 0 <= h < 24 and 0 <= m < 60:
            return f"{h:02d}:{m:02d}"
    except ValueError:
        pass
    return default


@router.get("/api/users/me/away")
async def get_away(user_id: str = Depends(require_auth)):
    row = await one("SELECT away FROM users WHERE id = $1", user_id)
    return {"away": row["away"] or {"enabled": False, "message": "", "mode": "outside", "from": "09:00", "to": "18:00",
                                     "days": [1, 2, 3, 4, 5, 6], "tzOffset": 330}}


@router.patch("/api/users/me/away")
async def set_away(request: Request, user_id: str = Depends(require_auth)):
    b = await request.json()
    message = str(b.get("message") or "").strip()[:500]
    enabled = bool(b.get("enabled"))
    if enabled and not message:
        raise HTTPException(400, "Write the away message first.")
    days = sorted({int(d) for d in (b.get("days") or []) if str(d).isdigit() and 1 <= int(d) <= 7})
    away = {
        "enabled": enabled, "message": message,
        "mode": "always" if b.get("mode") == "always" else "outside",
        "from": _hhmm(b.get("from"), "09:00"), "to": _hhmm(b.get("to"), "18:00"),
        "days": days or [1, 2, 3, 4, 5, 6, 7],
        "tzOffset": max(-720, min(840, int(b.get("tzOffset") or 0))),
    }
    await execute("UPDATE users SET away = $2 WHERE id = $1", user_id, away)
    return {"away": away}


def is_away(away: dict | None, now: datetime | None = None) -> bool:
    """Is the business 'away' right now by its own settings?"""
    if not away or not away.get("enabled") or not away.get("message"):
        return False
    if away.get("mode") == "always":
        return True
    local = (now or datetime.now(timezone.utc)) + timedelta(minutes=int(away.get("tzOffset") or 0))
    if local.isoweekday() not in (away.get("days") or []):
        return True
    t = local.strftime("%H:%M")
    start, end = away.get("from", "09:00"), away.get("to", "18:00")
    open_now = start <= t < end if start <= end else (t >= start or t < end)  # overnight hours
    return not open_now


async def maybe_auto_reply(conversation_id: str, sender_id: str, business_id: str):
    """Called after a message lands in a 1:1 chat. Sends the business's away
    message back (plain text, kind 'auto') at most once per 12 hours."""
    from app.websocket import manager as hub
    from app.utils.serializers import shape_message

    row = await one("SELECT away, business FROM users WHERE id = $1", business_id)
    if not row or not (row["business"] or {}).get("enabled") or not is_away(row["away"]):
        return
    recent = await one(
        "SELECT 1 FROM auto_reply_log WHERE business_id = $1 AND customer_id = $2 AND sent_at > now() - interval '12 hours'",
        business_id, sender_id,
    )
    if recent:
        return
    await execute(
        """INSERT INTO auto_reply_log (business_id, customer_id) VALUES ($1, $2)
           ON CONFLICT (business_id, customer_id) DO UPDATE SET sent_at = now()""",
        business_id, sender_id,
    )
    msg = await one(
        """INSERT INTO messages (conversation_id, sender_id, kind, ciphertext, iv)
           VALUES ($1, $2, 'auto', $3, 'plain')
           RETURNING id, sender_id, kind, ciphertext, iv, file_path, file_size, created_at, reply_to_id, view_once,
                     expires_at, poll_closes_at, mention_all""",
        conversation_id, business_id, row["away"]["message"],
    )
    await execute(
        "INSERT INTO message_receipts (message_id, user_id, delivered_at) VALUES ($1, $2, now())",
        msg["id"], sender_id,
    )
    payload = shape_message(msg)
    for uid in (sender_id, business_id):
        await hub.notify_user(uid, {"type": "message", "conversationId": conversation_id, "message": payload})


# ── Customer notes ───────────────────────────────────────────

async def _member(conversation_id: str, user_id: str):
    if not await one("SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2", conversation_id, user_id):
        raise HTTPException(404, "Not your conversation.")


@router.get("/api/conversations/{conversation_id}/note")
async def get_note(conversation_id: str, user_id: str = Depends(require_auth)):
    await _member(conversation_id, user_id)
    row = await one("SELECT ciphertext, iv, updated_at FROM chat_notes WHERE user_id = $1 AND conversation_id = $2", user_id, conversation_id)
    return {"note": {"ciphertext": row["ciphertext"], "iv": row["iv"], "updatedAt": row["updated_at"]} if row else None}


@router.put("/api/conversations/{conversation_id}/note")
async def put_note(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    await _member(conversation_id, user_id)
    b = await request.json()
    if not b.get("ciphertext"):
        await execute("DELETE FROM chat_notes WHERE user_id = $1 AND conversation_id = $2", user_id, conversation_id)
        return {"note": None}
    if len(str(b["ciphertext"])) > 20000:
        raise HTTPException(400, "That note is too long.")
    row = await one(
        """INSERT INTO chat_notes (user_id, conversation_id, ciphertext, iv) VALUES ($1, $2, $3, $4)
           ON CONFLICT (user_id, conversation_id) DO UPDATE SET ciphertext = EXCLUDED.ciphertext, iv = EXCLUDED.iv, updated_at = now()
           RETURNING updated_at""",
        user_id, conversation_id, b["ciphertext"], b.get("iv") or "",
    )
    return {"note": {"updatedAt": row["updated_at"]}}
