"""Broadcast lists — send one message to many people privately. The list is
only "who to send to": the app encrypts and sends a normal 1:1 message to
each member's own chat, so replies come back privately, one by one."""
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.database import are_accepted_contacts, one, query, transaction

router = APIRouter(prefix="/api/broadcasts", dependencies=[Depends(require_auth)])

MAX_MEMBERS = 256
MAX_LISTS = 50


async def _shape_all(user_id: str, list_id: str | None = None) -> list[dict]:
    rows = await query(
        f"""SELECT b.id, b.name, b.created_at,
                  COALESCE(array_agg(m.member_id) FILTER (WHERE m.member_id IS NOT NULL), '{{}}') AS member_ids
             FROM broadcast_lists b
             LEFT JOIN broadcast_list_members m ON m.list_id = b.id
            WHERE b.user_id = $1 {"AND b.id = $2" if list_id else ""}
            GROUP BY b.id
            ORDER BY b.created_at""",
        *((user_id, list_id) if list_id else (user_id,)),
    )
    return [{"id": r["id"], "name": r["name"], "memberIds": list(r["member_ids"]), "createdAt": r["created_at"]} for r in rows]


async def _clean(user_id: str, body: dict) -> tuple[str, list[str]]:
    name = str(body.get("name") or "").strip()[:60]
    members = body.get("memberIds")
    if not name:
        raise HTTPException(400, "Give the list a name.")
    if not isinstance(members, list) or not members:
        raise HTTPException(400, "Pick at least one person.")
    member_ids = list({str(m) for m in members if m and str(m) != user_id})
    if len(member_ids) > MAX_MEMBERS:
        raise HTTPException(400, f"A list can have up to {MAX_MEMBERS} people.")
    if not await are_accepted_contacts(user_id, member_ids):
        raise HTTPException(400, "You can only add people you already chat with.")
    return name, member_ids


@router.get("")
async def list_broadcasts(user_id: str = Depends(require_auth)):
    return {"lists": await _shape_all(user_id)}


@router.post("", status_code=201)
async def create_broadcast(request: Request, user_id: str = Depends(require_auth)):
    name, member_ids = await _clean(user_id, await request.json())
    count = await one("SELECT COUNT(*)::int AS n FROM broadcast_lists WHERE user_id = $1", user_id)
    if count["n"] >= MAX_LISTS:
        raise HTTPException(400, f"You can have up to {MAX_LISTS} broadcast lists.")
    async with transaction() as conn:
        row = await conn.fetchrow("INSERT INTO broadcast_lists (user_id, name) VALUES ($1, $2) RETURNING id", user_id, name)
        for mid in member_ids:
            await conn.execute("INSERT INTO broadcast_list_members (list_id, member_id) VALUES ($1, $2)", row["id"], mid)
    return {"list": (await _shape_all(user_id, row["id"]))[0]}


@router.put("/{list_id}")
async def update_broadcast(list_id: str, request: Request, user_id: str = Depends(require_auth)):
    name, member_ids = await _clean(user_id, await request.json())
    if not await one("SELECT 1 FROM broadcast_lists WHERE id = $1 AND user_id = $2", list_id, user_id):
        raise HTTPException(404, "List not found.")
    async with transaction() as conn:
        await conn.execute("UPDATE broadcast_lists SET name = $2 WHERE id = $1", list_id, name)
        await conn.execute("DELETE FROM broadcast_list_members WHERE list_id = $1", list_id)
        for mid in member_ids:
            await conn.execute("INSERT INTO broadcast_list_members (list_id, member_id) VALUES ($1, $2)", list_id, mid)
    return {"list": (await _shape_all(user_id, list_id))[0]}


@router.delete("/{list_id}")
async def delete_broadcast(list_id: str, user_id: str = Depends(require_auth)):
    await query("DELETE FROM broadcast_lists WHERE id = $1 AND user_id = $2", list_id, user_id)
    return {"ok": True}
