"""Quick replies — saved answers the user inserts by typing "/shortcut" in
the composer. They're the user's own templates (not chat content), stored
so the same list shows up on every device they use."""
import re

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import one, query

router = APIRouter(prefix="/api/quick-replies", dependencies=[Depends(require_auth)])

SHORTCUT_RE = re.compile(r"^[a-z0-9_-]{1,24}$", re.IGNORECASE)
MAX_REPLIES = 100


def shape(r: dict) -> dict:
    return {"id": r["id"], "shortcut": r["shortcut"], "body": r["body"], "createdAt": r["created_at"]}


def _clean(body: dict) -> tuple[str, str]:
    shortcut = str(body.get("shortcut") or "").strip().lstrip("/")
    text = str(body.get("body") or "").strip()
    if not SHORTCUT_RE.match(shortcut):
        raise HTTPException(400, "Shortcut: 1–24 letters, numbers, - or _ (no spaces).")
    if not text:
        raise HTTPException(400, "Write the reply text.")
    if len(text) > 2000:
        raise HTTPException(400, "Reply is too long (max 2000 characters).")
    return shortcut.lower(), text


@router.get("")
async def list_replies(user_id: str = Depends(require_auth)):
    rows = await query(
        "SELECT id, shortcut, body, created_at FROM quick_replies WHERE user_id = $1 ORDER BY lower(shortcut)",
        user_id,
    )
    return {"replies": [shape(r) for r in rows]}


@router.post("", status_code=201)
async def create_reply(request: Request, user_id: str = Depends(require_auth)):
    shortcut, text = _clean(await request.json())
    count = await one("SELECT COUNT(*)::int AS n FROM quick_replies WHERE user_id = $1", user_id)
    if count["n"] >= MAX_REPLIES:
        raise HTTPException(400, f"You can save up to {MAX_REPLIES} quick replies.")
    if await one("SELECT 1 FROM quick_replies WHERE user_id = $1 AND lower(shortcut) = $2", user_id, shortcut):
        raise HTTPException(409, f"You already have /{shortcut}.")
    row = await one(
        "INSERT INTO quick_replies (user_id, shortcut, body) VALUES ($1, $2, $3) RETURNING id, shortcut, body, created_at",
        user_id, shortcut, text,
    )
    return {"reply": shape(row)}


@router.patch("/{reply_id}")
async def update_reply(reply_id: str, request: Request, user_id: str = Depends(require_auth)):
    shortcut, text = _clean(await request.json())
    clash = await one(
        "SELECT 1 FROM quick_replies WHERE user_id = $1 AND lower(shortcut) = $2 AND id <> $3",
        user_id, shortcut, reply_id,
    )
    if clash:
        raise HTTPException(409, f"You already have /{shortcut}.")
    row = await one(
        """UPDATE quick_replies SET shortcut = $3, body = $4 WHERE id = $1 AND user_id = $2
           RETURNING id, shortcut, body, created_at""",
        reply_id, user_id, shortcut, text,
    )
    if not row:
        raise HTTPException(404, "Quick reply not found.")
    return {"reply": shape(row)}


@router.delete("/{reply_id}")
async def delete_reply(reply_id: str, user_id: str = Depends(require_auth)):
    await query("DELETE FROM quick_replies WHERE id = $1 AND user_id = $2", reply_id, user_id)
    return {"ok": True}
