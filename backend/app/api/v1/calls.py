"""Call history: my 1:1 calls (incoming / outgoing, answered / missed /
declined, with duration) and group calls I joined, plus the missed-call
badge."""
from fastapi import APIRouter, Depends

from app.core.database import execute, one, query
from app.core.security import require_auth

router = APIRouter()


@router.get("/api/calls")
async def call_history(user_id: str = Depends(require_auth)):
    rows = await query(
        """SELECT l.id, l.conversation_id, l.caller_id, l.callee_id, l.is_group, l.call_type, l.status,
                  l.started_at, l.answered_at, l.ended_at,
                  c.title AS group_title, c.avatar_color AS group_color,
                  p.id AS peer_id, p.username AS peer_username, p.display_name AS peer_name,
                  p.avatar_color AS peer_color, p.photo_path AS peer_photo
             FROM call_logs l
             JOIN conversations c ON c.id = l.conversation_id
             LEFT JOIN users p ON p.id = CASE WHEN l.caller_id = $1 THEN l.callee_id ELSE l.caller_id END AND NOT l.is_group
             JOIN users me ON me.id = $1
            WHERE (l.caller_id = $1 OR l.callee_id = $1)
              AND (me.calls_cleared_at IS NULL OR l.started_at > me.calls_cleared_at)
            ORDER BY l.started_at DESC LIMIT 150""",
        user_id,
    )
    out = []
    for r in rows:
        duration = None
        if r["answered_at"] and r["ended_at"]:
            duration = max(0, int((r["ended_at"] - r["answered_at"]).total_seconds()))
        out.append({
            "id": r["id"],
            "conversationId": r["conversation_id"],
            "isGroup": r["is_group"],
            "callType": r["call_type"],
            "status": r["status"],
            "direction": "outgoing" if str(r["caller_id"]) == str(user_id) else "incoming",
            "startedAt": r["started_at"],
            "duration": duration,
            "title": r["group_title"] if r["is_group"] else r["peer_name"],
            "peer": None if r["is_group"] else {
                "id": r["peer_id"], "username": r["peer_username"], "displayName": r["peer_name"],
                "avatarColor": r["peer_color"],
                "photoUrl": f"/api/users/{r['peer_id']}/photo" if r["peer_photo"] else None,
            },
            "avatarColor": r["group_color"] if r["is_group"] else r["peer_color"],
        })
    return {"calls": out}


@router.get("/api/calls/missed")
async def missed_count(user_id: str = Depends(require_auth)):
    row = await one(
        """SELECT count(*) AS n FROM call_logs l JOIN users me ON me.id = $1
            WHERE l.callee_id = $1 AND l.status = 'missed' AND l.started_at > me.calls_seen_at""",
        user_id,
    )
    return {"missed": row["n"]}


@router.post("/api/calls/seen")
async def calls_seen(user_id: str = Depends(require_auth)):
    await execute("UPDATE users SET calls_seen_at = now() WHERE id = $1", user_id)
    return {"missed": 0}


@router.delete("/api/calls")
async def clear_history(user_id: str = Depends(require_auth)):
    """Clears the list for me (the other person keeps theirs)."""
    await execute("UPDATE users SET calls_cleared_at = now(), calls_seen_at = now() WHERE id = $1", user_id)
    return {"ok": True}
