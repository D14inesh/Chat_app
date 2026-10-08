"""Mirrors src/routes/messages.js."""
from fastapi import APIRouter, Depends, HTTPException

from app.core.security import require_auth
from app.core.database import one, query

router = APIRouter(prefix="/api/messages", dependencies=[Depends(require_auth)])


@router.post("/{message_id}/star", status_code=201)
async def star_message(message_id: str, user_id: str = Depends(require_auth)):
    msg = await one(
        """SELECT m.conversation_id
             FROM messages m
             JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $2
            WHERE m.id = $1""",
        message_id, user_id,
    )
    if not msg:
        raise HTTPException(404, "Message not found.")
    await query("INSERT INTO message_stars (message_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", message_id, user_id)
    return {"starred": True}


@router.delete("/{message_id}/star")
async def unstar_message(message_id: str, user_id: str = Depends(require_auth)):
    await query("DELETE FROM message_stars WHERE message_id = $1 AND user_id = $2", message_id, user_id)
    return {"starred": False}


@router.post("/{message_id}/hide", status_code=201)
async def hide_message(message_id: str, user_id: str = Depends(require_auth)):
    msg = await one(
        """SELECT m.conversation_id
             FROM messages m
             JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = $2
            WHERE m.id = $1""",
        message_id, user_id,
    )
    if not msg:
        raise HTTPException(404, "Message not found.")
    await query("INSERT INTO message_hides (message_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", message_id, user_id)
    return {"hidden": True}


@router.get("/starred")
async def starred_messages(user_id: str = Depends(require_auth)):
    rows = await query(
        """SELECT m.id, m.conversation_id, m.sender_id, m.kind, m.ciphertext, m.iv,
                  m.file_path, m.file_size, m.created_at, ms.created_at AS starred_at
             FROM message_stars ms
             JOIN messages m ON m.id = ms.message_id
            WHERE ms.user_id = $1 AND m.deleted_at IS NULL
              AND (m.expires_at IS NULL OR m.expires_at > now())
            ORDER BY ms.created_at DESC""",
        user_id,
    )
    return {"starred": [{
        "id": r["id"], "conversationId": r["conversation_id"], "senderId": r["sender_id"],
        "kind": r["kind"], "ciphertext": r["ciphertext"], "iv": r["iv"],
        "filePath": r["file_path"], "fileSize": int(r["file_size"]) if r["file_size"] else None,
        "createdAt": r["created_at"], "starredAt": r["starred_at"],
    } for r in rows]}


@router.get("/{message_id}/info")
async def message_info(message_id: str, user_id: str = Depends(require_auth)):
    """Message info (my own messages): when each person got it and read it.
    In a 1-to-1 chat, "read" stays hidden if either person turned read
    receipts off."""
    from app.utils.privacy import reads_hidden

    msg = await one("SELECT conversation_id, sender_id, created_at FROM messages WHERE id = $1 AND deleted_at IS NULL", message_id)
    if not msg or str(msg["sender_id"]) != str(user_id):
        raise HTTPException(404, "Message not found.")
    hide = await reads_hidden(str(msg["conversation_id"]))
    rows = await query(
        """SELECT u.id, u.display_name, r.delivered_at, r.read_at
             FROM message_receipts r JOIN users u ON u.id = r.user_id
            WHERE r.message_id = $1
            ORDER BY r.read_at NULLS LAST, r.delivered_at NULLS LAST, u.display_name""",
        message_id,
    )
    return {
        "sentAt": msg["created_at"],
        "readsHidden": hide,
        "recipients": [{
            "userId": r["id"], "name": r["display_name"],
            "deliveredAt": r["delivered_at"] or r["read_at"],
            "readAt": None if hide else r["read_at"],
        } for r in rows],
    }
