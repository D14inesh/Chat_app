"""Mirrors src/routes/reminders.js."""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import execute, one, query, row_count

router = APIRouter(prefix="/api/reminders", dependencies=[Depends(require_auth)])

CATEGORIES = {"birthday", "happy", "love", "sad", "breakup", "general"}


def shape(r: dict) -> dict:
    return {
        "id": r["id"], "content": r["content"], "category": r["category"],
        "remindAt": r["remind_at"], "notifiedAt": r["notified_at"], "createdAt": r["created_at"],
    }


@router.get("")
async def list_reminders(user_id: str = Depends(require_auth)):
    rows = await query(
        "SELECT id, content, category, remind_at, notified_at, created_at FROM reminders WHERE user_id = $1 ORDER BY remind_at ASC",
        user_id,
    )
    return {"reminders": [shape(r) for r in rows]}


@router.post("", status_code=201)
async def create_reminder(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    content = str(body.get("content") or "").strip()
    category = body.get("category") or "general"
    remind_at_raw = body.get("remindAt")

    try:
        remind_at = datetime.fromisoformat(str(remind_at_raw).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        raise HTTPException(400, "Pick a valid date and time.")

    if not content:
        raise HTTPException(400, "Write what this reminder is about.")
    if len(content) > 2000:
        raise HTTPException(400, "That note is too long.")
    if category not in CATEGORIES:
        raise HTTPException(400, "Unknown reminder type.")
    if remind_at < datetime.now(timezone.utc) - timedelta(seconds=60):
        raise HTTPException(400, "Pick a date and time in the future.")

    row = await one(
        "INSERT INTO reminders (user_id, content, category, remind_at) VALUES ($1, $2, $3, $4) "
        "RETURNING id, content, category, remind_at, notified_at, created_at",
        user_id, content, category, remind_at,
    )
    return {"reminder": shape(row)}


@router.delete("/{reminder_id}")
async def delete_reminder(reminder_id: str, user_id: str = Depends(require_auth)):
    status = await execute("DELETE FROM reminders WHERE id = $1 AND user_id = $2", reminder_id, user_id)
    if not row_count(status):
        raise HTTPException(404, "Reminder not found.")
    return {"ok": True}
