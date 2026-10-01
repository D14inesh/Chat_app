"""Mirrors src/routes/scheduled.js — mounted at the same /api/conversations
prefix as routes/conversations.py, exactly like the Node app mounts both
routers on that path."""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import execute, one, query, row_count

router = APIRouter(prefix="/api/conversations", dependencies=[Depends(require_auth)])


def shape(r: dict) -> dict:
    return {
        "id": r["id"], "ciphertext": r["ciphertext"], "iv": r["iv"],
        "sendAt": r["send_at"], "sentAt": r["sent_at"], "createdAt": r["created_at"],
    }


@router.post("/{conversation_id}/scheduled-messages", status_code=201)
async def create_scheduled_message(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    ciphertext = body.get("ciphertext")
    iv = body.get("iv")

    try:
        send_at = datetime.fromisoformat(str(body.get("sendAt")).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        raise HTTPException(400, "Pick a valid date and time.")

    if not ciphertext or not iv:
        raise HTTPException(400, "Missing message content.")
    if send_at < datetime.now(timezone.utc) - timedelta(seconds=60):
        raise HTTPException(400, "Pick a date and time in the future.")

    member = await one(
        """SELECT c.kind, c.status, c.requested_by
             FROM conversation_members cm
             JOIN conversations c ON c.id = cm.conversation_id
            WHERE cm.conversation_id = $1 AND cm.user_id = $2""",
        conversation_id, user_id,
    )
    if not member:
        raise HTTPException(403, "Not your conversation.")
    if member["kind"] == "direct" and member["status"] == "pending" and member["requested_by"] != user_id:
        raise HTTPException(403, "Accept the request before you can schedule a message here.")

    row = await one(
        """INSERT INTO scheduled_messages (conversation_id, sender_id, ciphertext, iv, send_at)
           VALUES ($1, $2, $3, $4, $5)
           RETURNING id, ciphertext, iv, send_at, sent_at, created_at""",
        conversation_id, user_id, ciphertext, iv, send_at,
    )
    return {"scheduledMessage": shape(row)}


@router.get("/{conversation_id}/scheduled-messages")
async def list_scheduled_messages(conversation_id: str, user_id: str = Depends(require_auth)):
    rows = await query(
        """SELECT id, ciphertext, iv, send_at, sent_at, created_at
             FROM scheduled_messages
            WHERE conversation_id = $1 AND sender_id = $2 AND sent_at IS NULL
            ORDER BY send_at ASC""",
        conversation_id, user_id,
    )
    return {"scheduledMessages": [shape(r) for r in rows]}


@router.delete("/{conversation_id}/scheduled-messages/{message_id}")
async def cancel_scheduled_message(conversation_id: str, message_id: str, user_id: str = Depends(require_auth)):
    status = await execute(
        "DELETE FROM scheduled_messages WHERE id = $1 AND conversation_id = $2 AND sender_id = $3 AND sent_at IS NULL",
        message_id, conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(404, "Not found, or it already sent.")
    return {"ok": True}
