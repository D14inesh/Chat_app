"""Mirrors src/routes/conversations.js â€” see that file's comments for the
full reasoning behind each query; kept here only where a Python-specific
note is needed."""
import os
import secrets
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse

from app.core.security import require_auth
from app.core.config import WALLPAPER_DIR
from app.core.database import are_accepted_contacts, execute, is_blocked_either_way, one, query, row_count, transaction
from app.utils.serializers import shape_conversation, shape_message
from app.websocket import manager as hub

router = APIRouter(prefix="/api/conversations", dependencies=[Depends(require_auth)])

os.makedirs(WALLPAPER_DIR, exist_ok=True)

WALLPAPER_EXT_BY_MIME = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
MAX_WALLPAPER_BYTES = 8 * 1024 * 1024

WALLPAPER_KEYS = {
    "dawn", "sunset", "forest", "ocean", "rose", "slate",
    "midnight", "peach", "mint", "lavender", "amber", "coral",
}
WALLPAPER_FIT_KEYS = {"cover", "contain", "fill", "tile"}

MESSAGE_COLUMNS = """m.id, m.sender_id, m.kind, m.ciphertext, m.iv, m.file_path, m.file_size,
                     m.created_at, m.edited_at, m.reply_to_id, m.view_once, m.expires_at"""


async def message_extras(message_ids: list[str]) -> tuple[dict, dict, dict]:
    """Reactions, poll votes and view-once opens for a batch of messages."""
    reactions: dict[str, list] = {}
    votes: dict[str, list] = {}
    opens: dict[str, list] = {}
    if not message_ids:
        return reactions, votes, opens
    for r in await query(
        "SELECT message_id, user_id, ciphertext, iv FROM message_reactions WHERE message_id = ANY($1::uuid[])",
        message_ids,
    ):
        reactions.setdefault(r["message_id"], []).append({"userId": r["user_id"], "ciphertext": r["ciphertext"], "iv": r["iv"]})
    for r in await query(
        "SELECT message_id, user_id, choices FROM poll_votes WHERE message_id = ANY($1::uuid[]) ORDER BY voted_at",
        message_ids,
    ):
        votes.setdefault(r["message_id"], []).append({"userId": r["user_id"], "choices": list(r["choices"])})
    for r in await query(
        "SELECT message_id, user_id FROM message_opens WHERE message_id = ANY($1::uuid[])",
        message_ids,
    ):
        opens.setdefault(r["message_id"], []).append(r["user_id"])
    return reactions, votes, opens


@router.get("")
async def list_conversations(user_id: str = Depends(require_auth)):
    rows = await query(
        """WITH mine AS (
             SELECT conversation_id, favorite, wallpaper, wallpaper_photo_path, wallpaper_fit,
                    muted, cleared_at, hidden_at
               FROM conversation_members WHERE user_id = $1
           ),
           peer AS (
             SELECT cm.conversation_id, u.id, u.username, u.display_name,
                    u.avatar_color, u.about, u.photo_path, u.last_seen, u.public_key
               FROM conversation_members cm
               JOIN conversations c ON c.id = cm.conversation_id AND c.kind = 'direct'
               JOIN users u ON u.id = cm.user_id
              WHERE cm.conversation_id IN (SELECT conversation_id FROM mine)
                AND cm.user_id <> $1
           ),
           group_info AS (
             SELECT c.id AS conversation_id, COUNT(cm.user_id)::int AS member_count
               FROM conversations c
               JOIN conversation_members cm ON cm.conversation_id = c.id
              WHERE c.kind = 'group' AND c.id IN (SELECT conversation_id FROM mine)
              GROUP BY c.id
           ),
           last_msg AS (
             SELECT DISTINCT ON (m.conversation_id)
                    m.conversation_id, m.id, m.sender_id, m.kind, m.ciphertext, m.iv,
                    m.created_at, m.view_once,
                    (SELECT MIN(delivered_at) FROM message_receipts WHERE message_id = m.id) AS delivered_at,
                    (SELECT CASE WHEN bool_and(read_at IS NOT NULL) THEN MAX(read_at) ELSE NULL END
                       FROM message_receipts WHERE message_id = m.id) AS read_at
               FROM messages m
               JOIN mine ON mine.conversation_id = m.conversation_id
              WHERE m.deleted_at IS NULL
                AND (m.expires_at IS NULL OR m.expires_at > now())
                AND m.created_at > COALESCE(mine.cleared_at, '-infinity'::timestamptz)
                AND NOT EXISTS (
                  SELECT 1 FROM message_hides mh WHERE mh.message_id = m.id AND mh.user_id = $1
                )
              ORDER BY m.conversation_id, m.created_at DESC
           ),
           unread AS (
             SELECT m.conversation_id, COUNT(*)::int AS n
               FROM message_receipts r
               JOIN messages m ON m.id = r.message_id
              WHERE r.user_id = $1 AND r.read_at IS NULL
              GROUP BY m.conversation_id
           )
           SELECT c.id, c.kind, c.title, c.avatar_color AS group_avatar_color,
                  c.status, c.requested_by, c.disappear_seconds, c.pinned_message_id, c.pinned_by,
                  p.id AS peer_id, p.username AS peer_username,
                  p.display_name AS peer_name, p.avatar_color AS peer_color,
                  p.about AS peer_about, p.photo_path AS peer_photo_path,
                  p.last_seen AS peer_last_seen, p.public_key AS peer_public_key,
                  COALESCE(gi.member_count, 0) AS member_count,
                  lm.id AS last_id, lm.sender_id AS last_sender,
                  lm.kind AS last_kind, lm.ciphertext AS last_ciphertext,
                  lm.iv AS last_iv, lm.created_at AS last_at,
                  lm.delivered_at AS last_delivered, lm.read_at AS last_read, lm.view_once AS last_view_once,
                  COALESCE(un.n, 0) AS unread,
                  mm.favorite, mm.wallpaper, mm.wallpaper_photo_path, mm.wallpaper_fit, mm.muted
             FROM conversations c
             LEFT JOIN mine mm       ON mm.conversation_id = c.id
             LEFT JOIN peer p        ON p.conversation_id = c.id
             LEFT JOIN group_info gi ON gi.conversation_id = c.id
             LEFT JOIN last_msg lm   ON lm.conversation_id = c.id
             LEFT JOIN unread un     ON un.conversation_id = c.id
            WHERE c.id IN (SELECT conversation_id FROM mine)
              AND (mm.hidden_at IS NULL OR lm.created_at > mm.hidden_at)
            ORDER BY COALESCE(lm.created_at, c.created_at) DESC""",
        user_id,
    )

    # Pinned messages, fetched in one go (they're often older than anything
    # the chat has loaded, so the client can't just look them up).
    pinned_ids = [r["pinned_message_id"] for r in rows if r.get("pinned_message_id")]
    pinned: dict[str, dict] = {}
    if pinned_ids:
        for m in await query(
            f"""SELECT {MESSAGE_COLUMNS} FROM messages m
                 WHERE m.id = ANY($1::uuid[]) AND m.deleted_at IS NULL
                   AND (m.expires_at IS NULL OR m.expires_at > now())""",
            pinned_ids,
        ):
            pinned[m["id"]] = shape_message(m)
    for r in rows:
        r["pinned_message"] = pinned.get(r.get("pinned_message_id"))
        if not r["pinned_message"]:
            r["pinned_by"] = None
    return {"conversations": [shape_conversation(r) for r in rows]}


@router.post("/direct")
async def open_direct(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    peer_id = body.get("userId")
    if not peer_id or peer_id == user_id:
        raise HTTPException(400, "Pick someone else to chat with.")

    peer = await one(
        "SELECT id, username, display_name, avatar_color, about, photo_path, last_seen, public_key FROM users WHERE id = $1",
        peer_id,
    )
    if not peer:
        raise HTTPException(404, "No such user.")

    if await is_blocked_either_way(user_id, peer_id):
        raise HTTPException(403, "You can't start a chat with this person.")

    direct_key = ":".join(sorted([user_id, peer_id]))

    async with transaction() as conn:
        row = await conn.fetchrow(
            """INSERT INTO conversations (kind, direct_key, status, requested_by)
               VALUES ('direct', $1, 'pending', $2)
               ON CONFLICT (direct_key) DO UPDATE SET direct_key = EXCLUDED.direct_key
               RETURNING id, status, requested_by""",
            direct_key, user_id,
        )
        created = dict(row)
        await conn.execute(
            "INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2), ($1, $3) ON CONFLICT DO NOTHING",
            created["id"], user_id, peer_id,
        )

    return {"conversation": shape_conversation({
        "id": created["id"], "kind": "direct", "status": created["status"], "requested_by": created["requested_by"],
        "peer_id": peer["id"], "peer_username": peer["username"], "peer_name": peer["display_name"],
        "peer_color": peer["avatar_color"], "peer_about": peer["about"], "peer_photo_path": peer["photo_path"],
        "peer_last_seen": peer["last_seen"], "peer_public_key": peer["public_key"], "unread": 0,
    })}


@router.post("/{conversation_id}/accept")
async def accept_request(conversation_id: str, user_id: str = Depends(require_auth)):
    convo = await one("SELECT kind, status, requested_by FROM conversations WHERE id = $1", conversation_id)
    if not convo or convo["kind"] != "direct":
        raise HTTPException(404, "No such conversation.")
    if convo["status"] != "pending":
        raise HTTPException(400, "This request was already handled.")
    if convo["requested_by"] == user_id:
        raise HTTPException(403, "You sent this request â€” the other person needs to accept it.")

    await query("UPDATE conversations SET status = 'accepted' WHERE id = $1", conversation_id)
    await hub.notify_user(convo["requested_by"], {"type": "request-accepted", "conversationId": conversation_id})
    return {"ok": True}


@router.post("/{conversation_id}/decline")
async def decline_request(conversation_id: str, user_id: str = Depends(require_auth)):
    convo = await one("SELECT kind, status, requested_by FROM conversations WHERE id = $1", conversation_id)
    if not convo or convo["kind"] != "direct":
        raise HTTPException(404, "No such conversation.")
    if convo["status"] != "pending":
        raise HTTPException(400, "This request was already handled.")
    if convo["requested_by"] == user_id:
        raise HTTPException(403, "You sent this request â€” the other person needs to decline it.")

    async with transaction() as conn:
        await conn.execute("DELETE FROM conversations WHERE id = $1", conversation_id)

    await hub.notify_user(convo["requested_by"], {"type": "request-declined", "conversationId": conversation_id})
    return {"ok": True}


@router.post("/group", status_code=201)
async def create_group(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    title = str(body.get("title") or "").strip()[:80]
    avatar_color = body.get("avatarColor") or "#6C5CE7"
    members = body.get("members")

    if not title:
        raise HTTPException(400, "A group needs a name.")
    if not isinstance(members, list) or len(members) < 1:
        raise HTTPException(400, "Add at least one other member.")
    if any(not m.get("userId") or not m.get("wrappedKey") or not m.get("wrappedIv") for m in members):
        raise HTTPException(400, "Malformed member key data.")
    if not any(m["userId"] == user_id for m in members):
        raise HTTPException(400, "Missing a key for yourself â€” cannot create the group.")

    member_ids_ = list({m["userId"] for m in members})
    found = await query("SELECT id FROM users WHERE id = ANY($1::uuid[])", member_ids_)
    if len(found) != len(member_ids_):
        raise HTTPException(400, "One of those users does not exist.")

    others = [i for i in member_ids_ if i != user_id]
    if not await are_accepted_contacts(user_id, others):
        raise HTTPException(400, "You can only add people you already have an accepted chat with.")

    async with transaction() as conn:
        row = await conn.fetchrow(
            "INSERT INTO conversations (kind, title, avatar_color) VALUES ('group', $1, $2) RETURNING id",
            title, avatar_color,
        )
        conversation_id = row["id"]
        for m in members:
            await conn.execute(
                "INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, $3)",
                conversation_id, m["userId"], "owner" if m["userId"] == user_id else "member",
            )
            await conn.execute(
                """INSERT INTO group_keys (conversation_id, user_id, wrapped_key, wrapped_iv, wrapped_by)
                   VALUES ($1, $2, $3, $4, $5)""",
                conversation_id, m["userId"], m["wrappedKey"], m["wrappedIv"], user_id,
            )

    return {"conversation": shape_conversation({
        "id": conversation_id, "kind": "group", "title": title, "group_avatar_color": avatar_color,
        "member_count": len(member_ids_), "unread": 0,
    })}


@router.post("/{conversation_id}/members")
async def add_member(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    target_user_id = body.get("userId")
    wrapped_key = body.get("wrappedKey")
    wrapped_iv = body.get("wrappedIv")

    owner = await one(
        "SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2 AND role = 'owner'",
        conversation_id, user_id,
    )
    if not owner:
        raise HTTPException(403, "Only the group owner can add members.")
    if not target_user_id or not wrapped_key or not wrapped_iv:
        raise HTTPException(400, "Missing member or key data.")

    user = await one("SELECT 1 FROM users WHERE id = $1", target_user_id)
    if not user:
        raise HTTPException(404, "No such user.")

    async with transaction() as conn:
        await conn.execute(
            "INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            conversation_id, target_user_id,
        )
        await conn.execute(
            """INSERT INTO group_keys (conversation_id, user_id, wrapped_key, wrapped_iv, wrapped_by)
               VALUES ($1, $2, $3, $4, $5)
               ON CONFLICT (conversation_id, user_id) DO UPDATE
                 SET wrapped_key = EXCLUDED.wrapped_key, wrapped_iv = EXCLUDED.wrapped_iv, wrapped_by = EXCLUDED.wrapped_by""",
            conversation_id, target_user_id, wrapped_key, wrapped_iv, user_id,
        )
    return {"ok": True}


@router.delete("/{conversation_id}/members/{target_user_id}")
async def remove_member(conversation_id: str, target_user_id: str, user_id: str = Depends(require_auth)):
    if target_user_id != user_id:
        owner = await one(
            "SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2 AND role = 'owner'",
            conversation_id, user_id,
        )
        if not owner:
            raise HTTPException(403, "Only the group owner can remove members.")

    async with transaction() as conn:
        await conn.execute("DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2", conversation_id, target_user_id)
        await conn.execute("DELETE FROM group_keys WHERE conversation_id = $1 AND user_id = $2", conversation_id, target_user_id)
    return {"ok": True}


@router.get("/{conversation_id}/members")
async def list_members(conversation_id: str, user_id: str = Depends(require_auth)):
    member = await one("SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2", conversation_id, user_id)
    if not member:
        raise HTTPException(403, "Not your conversation.")

    rows = await query(
        """SELECT u.id, u.username, u.display_name, u.avatar_color, u.photo_path, u.public_key, cm.role
             FROM conversation_members cm
             JOIN users u ON u.id = cm.user_id
            WHERE cm.conversation_id = $1
            ORDER BY (cm.role = 'owner') DESC, u.display_name""",
        conversation_id,
    )
    return {"members": [{
        "id": r["id"], "username": r["username"], "displayName": r["display_name"],
        "avatarColor": r["avatar_color"],
        "photoUrl": f"/api/users/{r['id']}/photo" if r["photo_path"] else None,
        "publicKey": r["public_key"], "role": r["role"],
    } for r in rows]}


@router.patch("/{conversation_id}/favorite")
async def set_favorite(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    favorite = bool(body.get("favorite"))
    status = await execute(
        "UPDATE conversation_members SET favorite = $1 WHERE conversation_id = $2 AND user_id = $3",
        favorite, conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"favorite": favorite}


@router.patch("/{conversation_id}/mute")
async def set_muted(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    muted = bool(body.get("muted"))
    status = await execute(
        "UPDATE conversation_members SET muted = $1 WHERE conversation_id = $2 AND user_id = $3",
        muted, conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"muted": muted}


@router.post("/{conversation_id}/clear")
async def clear_chat(conversation_id: str, user_id: str = Depends(require_auth)):
    status = await execute(
        "UPDATE conversation_members SET cleared_at = now() WHERE conversation_id = $1 AND user_id = $2",
        conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"ok": True}


@router.delete("/{conversation_id}")
async def hide_chat(conversation_id: str, user_id: str = Depends(require_auth)):
    status = await execute(
        "UPDATE conversation_members SET hidden_at = now() WHERE conversation_id = $1 AND user_id = $2",
        conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"ok": True}


@router.patch("/{conversation_id}/wallpaper")
async def set_wallpaper(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    wallpaper = body.get("wallpaper")
    if wallpaper is not None and wallpaper not in WALLPAPER_KEYS:
        raise HTTPException(400, "Unknown wallpaper.")
    status = await execute(
        "UPDATE conversation_members SET wallpaper = $1 WHERE conversation_id = $2 AND user_id = $3",
        wallpaper, conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"wallpaper": wallpaper}


@router.post("/{conversation_id}/wallpaper-photo", status_code=201)
async def upload_wallpaper_photo(conversation_id: str, photo: UploadFile = File(...), user_id: str = Depends(require_auth)):

    ext = WALLPAPER_EXT_BY_MIME.get(photo.content_type)
    if not ext:
        raise HTTPException(400, "Please upload a JPEG, PNG, or WebP image.")

    data = await photo.read()
    if len(data) > MAX_WALLPAPER_BYTES:
        raise HTTPException(413, f"Image is too large (limit {MAX_WALLPAPER_BYTES // 1024 // 1024} MB).")

    member = await one(
        "SELECT wallpaper_photo_path FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
        conversation_id, user_id,
    )
    if not member:
        raise HTTPException(403, "Not your conversation.")

    filename = f"{secrets.token_hex(24)}{ext}"
    (Path(WALLPAPER_DIR) / filename).write_bytes(data)

    await execute(
        "UPDATE conversation_members SET wallpaper = 'photo', wallpaper_photo_path = $1 WHERE conversation_id = $2 AND user_id = $3",
        filename, conversation_id, user_id,
    )

    if member["wallpaper_photo_path"]:
        old = Path(WALLPAPER_DIR) / member["wallpaper_photo_path"]
        old.unlink(missing_ok=True)

    return {"wallpaper": "photo", "wallpaperPhotoUrl": f"/api/conversations/{conversation_id}/wallpaper-photo"}


@router.get("/{conversation_id}/wallpaper-photo")
async def get_wallpaper_photo(conversation_id: str, user_id: str = Depends(require_auth)):
    member = await one(
        "SELECT wallpaper_photo_path FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
        conversation_id, user_id,
    )
    if not member or not member["wallpaper_photo_path"]:
        raise HTTPException(404, "No wallpaper photo.")
    full = Path(WALLPAPER_DIR) / member["wallpaper_photo_path"]
    if not full.exists():
        raise HTTPException(404, "No wallpaper photo.")
    return FileResponse(full)


@router.patch("/{conversation_id}/wallpaper-fit")
async def set_wallpaper_fit(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    fit = body.get("fit")
    if fit not in WALLPAPER_FIT_KEYS:
        raise HTTPException(400, "Unknown wallpaper fit.")
    status = await execute(
        "UPDATE conversation_members SET wallpaper_fit = $1 WHERE conversation_id = $2 AND user_id = $3",
        fit, conversation_id, user_id,
    )
    if not row_count(status):
        raise HTTPException(403, "Not your conversation.")
    return {"fit": fit}


@router.get("/{conversation_id}/key")
async def get_group_key(conversation_id: str, user_id: str = Depends(require_auth)):
    row = await one(
        """SELECT gk.wrapped_key, gk.wrapped_iv, gk.wrapped_by
             FROM group_keys gk
             JOIN conversation_members cm
               ON cm.conversation_id = gk.conversation_id AND cm.user_id = gk.user_id
            WHERE gk.conversation_id = $1 AND gk.user_id = $2""",
        conversation_id, user_id,
    )
    if not row:
        raise HTTPException(404, "No key found for you in this group.")
    return {"wrappedKey": row["wrapped_key"], "wrappedIv": row["wrapped_iv"], "wrappedBy": row["wrapped_by"]}


@router.get("/{conversation_id}/messages")
async def list_messages(conversation_id: str, before: str | None = None, user_id: str = Depends(require_auth)):
    member = await one(
        "SELECT cleared_at FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
        conversation_id, user_id,
    )
    if not member:
        raise HTTPException(403, "Not your conversation.")

    before_dt = datetime.fromisoformat(before.replace("Z", "+00:00")) if before else None

    rows = await query(
        f"""SELECT {MESSAGE_COLUMNS},
                  (SELECT MIN(delivered_at) FROM message_receipts WHERE message_id = m.id) AS delivered_at,
                  (SELECT CASE WHEN bool_and(read_at IS NOT NULL) THEN MAX(read_at) ELSE NULL END
                     FROM message_receipts WHERE message_id = m.id) AS read_at
             FROM messages m
            WHERE m.conversation_id = $1
              AND m.deleted_at IS NULL
              AND (m.expires_at IS NULL OR m.expires_at > now())
              AND ($2::timestamptz IS NULL OR m.created_at < $2)
              AND m.created_at > COALESCE($3::timestamptz, '-infinity'::timestamptz)
              AND NOT EXISTS (
                SELECT 1 FROM message_hides mh WHERE mh.message_id = m.id AND mh.user_id = $4
              )
            ORDER BY m.created_at DESC
            LIMIT 50""",
        conversation_id, before_dt, member["cleared_at"], user_id,
    )

    reactions, votes, opens = await message_extras([r["id"] for r in rows])

    rows.reverse()  # query pulls newest-first for LIMIT; the UI wants oldest-first
    return {"messages": [
        shape_message(r, reactions.get(r["id"], []), votes.get(r["id"], []), opens.get(r["id"], []))
        for r in rows
    ]}
