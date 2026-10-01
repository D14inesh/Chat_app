"""Mirrors src/routes/labels.js."""
import re

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import execute, one, query, row_count

router = APIRouter(prefix="/api/labels", dependencies=[Depends(require_auth)])

HEX_COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


@router.get("")
async def list_labels(user_id: str = Depends(require_auth)):
    rows = await query(
        """SELECT l.id, l.name, l.color,
                  COALESCE(array_agg(cll.conversation_id) FILTER (WHERE cll.conversation_id IS NOT NULL), '{}') AS conversation_ids
             FROM chat_labels l
             LEFT JOIN conversation_label_links cll ON cll.label_id = l.id AND cll.user_id = l.user_id
            WHERE l.user_id = $1
            GROUP BY l.id
            ORDER BY l.created_at""",
        user_id,
    )
    return {"labels": [{"id": r["id"], "name": r["name"], "color": r["color"], "conversationIds": r["conversation_ids"]} for r in rows]}


@router.post("", status_code=201)
async def create_label(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    name = str(body.get("name") or "").strip()[:40]
    color = body.get("color") if HEX_COLOR_RE.match(body.get("color") or "") else "#A76BC9"
    if not name:
        raise HTTPException(400, "Give this list a name.")

    row = await one("INSERT INTO chat_labels (user_id, name, color) VALUES ($1, $2, $3) RETURNING id, name, color", user_id, name, color)
    return {"label": {**row, "conversationIds": []}}


@router.delete("/{label_id}")
async def delete_label(label_id: str, user_id: str = Depends(require_auth)):
    status = await execute("DELETE FROM chat_labels WHERE id = $1 AND user_id = $2", label_id, user_id)
    if not row_count(status):
        raise HTTPException(404, "Not found.")
    return {"ok": True}


@router.post("/{label_id}/toggle")
async def toggle_label(label_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    conversation_id = body.get("conversationId")
    if not conversation_id:
        raise HTTPException(400, "Missing conversationId.")

    label = await one("SELECT 1 FROM chat_labels WHERE id = $1 AND user_id = $2", label_id, user_id)
    if not label:
        raise HTTPException(404, "Not found.")

    existing = await one(
        "SELECT 1 FROM conversation_label_links WHERE conversation_id = $1 AND label_id = $2 AND user_id = $3",
        conversation_id, label_id, user_id,
    )

    if existing:
        await query(
            "DELETE FROM conversation_label_links WHERE conversation_id = $1 AND label_id = $2 AND user_id = $3",
            conversation_id, label_id, user_id,
        )
        return {"applied": False}

    await query(
        "INSERT INTO conversation_label_links (conversation_id, label_id, user_id) VALUES ($1, $2, $3)",
        conversation_id, label_id, user_id,
    )
    return {"applied": True}
