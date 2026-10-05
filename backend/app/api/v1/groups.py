"""Group admin features: settings, admin roles, invite links with approval,
and communities (several groups under one name + an announcements group).

Adding someone to a group always happens from an admin's app, because
only a member's app can wrap the group's encryption key for the newcomer
(POST /api/conversations/{id}/members). Join requests just queue people
up for that."""
import secrets

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.database import execute, one, query
from app.core.security import require_auth
from app.websocket import manager as hub

router = APIRouter()

ROLES = ("owner", "admin", "member")


async def role_of(conversation_id: str, user_id: str) -> str | None:
    row = await one(
        """SELECT cm.role FROM conversation_members cm JOIN conversations c ON c.id = cm.conversation_id
            WHERE cm.conversation_id = $1 AND cm.user_id = $2 AND c.kind = 'group'""",
        conversation_id, user_id,
    )
    return row["role"] if row else None


async def require_group_admin(conversation_id: str, user_id: str) -> str:
    role = await role_of(conversation_id, user_id)
    if role not in ("owner", "admin"):
        raise HTTPException(403, "Only group admins can do that.")
    return role


async def notify_members(conversation_id: str, frame: dict):
    for uid in await hub.member_ids(conversation_id):
        await hub.notify_user(uid, frame)


def _user(r: dict) -> dict:
    return {
        "id": r["id"], "username": r["username"], "displayName": r["display_name"],
        "avatarColor": r["avatar_color"],
        "photoUrl": f"/api/users/{r['id']}/photo" if r.get("photo_path") else None,
        "publicKey": r.get("public_key"),
    }


# ── Settings & roles ─────────────────────────────────────────

@router.patch("/api/conversations/{conversation_id}/group-settings")
async def group_settings(conversation_id: str, request: Request, user_id: str = Depends(require_auth)):
    await require_group_admin(conversation_id, user_id)
    body = await request.json()
    sets, args = [], [conversation_id]
    if "title" in body:
        title = str(body.get("title") or "").strip()[:80]
        if not title:
            raise HTTPException(400, "A group needs a name.")
        args.append(title)
        sets.append(f"title = ${len(args)}")
    if "description" in body:
        args.append(str(body.get("description") or "").strip()[:500])
        sets.append(f"description = ${len(args)}")
    if "onlyAdminsSend" in body:
        args.append(bool(body.get("onlyAdminsSend")))
        sets.append(f"only_admins_send = ${len(args)}")
    if not sets:
        raise HTTPException(400, "Nothing to change.")
    row = await one(
        f"""UPDATE conversations SET {', '.join(sets)} WHERE id = $1
            RETURNING title, description, only_admins_send, is_announcement""",
        *args,
    )
    if row["is_announcement"] and not row["only_admins_send"]:
        # A community's announcements group stays admin-only.
        row = await one("UPDATE conversations SET only_admins_send = true WHERE id = $1 RETURNING title, description, only_admins_send", conversation_id)
    update = {"title": row["title"], "description": row["description"] or "", "onlyAdminsSend": row["only_admins_send"]}
    await notify_members(conversation_id, {"type": "group-updated", "conversationId": conversation_id, **update, "by": user_id})
    return update


@router.patch("/api/conversations/{conversation_id}/members/{target_id}/role")
async def set_role(conversation_id: str, target_id: str, request: Request, user_id: str = Depends(require_auth)):
    if await role_of(conversation_id, user_id) != "owner":
        raise HTTPException(403, "Only the group owner can choose admins.")
    role = (await request.json()).get("role")
    if role not in ("admin", "member"):
        raise HTTPException(400, "Role must be admin or member.")
    current = await role_of(conversation_id, target_id)
    if current is None:
        raise HTTPException(404, "They're not in this group.")
    if current == "owner":
        raise HTTPException(400, "The owner stays the owner.")
    await execute("UPDATE conversation_members SET role = $3 WHERE conversation_id = $1 AND user_id = $2",
                  conversation_id, target_id, role)
    await notify_members(conversation_id, {"type": "members-changed", "conversationId": conversation_id})
    return {"ok": True, "role": role}


# ── Invite links & join requests ─────────────────────────────

@router.post("/api/conversations/{conversation_id}/invite")
async def new_invite(conversation_id: str, user_id: str = Depends(require_auth)):
    """Makes (or replaces — the old link stops working) the invite link."""
    await require_group_admin(conversation_id, user_id)
    code = secrets.token_urlsafe(9)
    await execute("UPDATE conversations SET invite_code = $2 WHERE id = $1", conversation_id, code)
    return {"inviteCode": code}


@router.delete("/api/conversations/{conversation_id}/invite")
async def revoke_invite(conversation_id: str, user_id: str = Depends(require_auth)):
    await require_group_admin(conversation_id, user_id)
    await execute("UPDATE conversations SET invite_code = NULL WHERE id = $1", conversation_id)
    return {"inviteCode": None}


async def _by_code(code: str) -> dict:
    row = await one(
        """SELECT c.id, c.title, c.description, c.avatar_color,
                  (SELECT count(*) FROM conversation_members cm WHERE cm.conversation_id = c.id) AS members
             FROM conversations c WHERE c.invite_code = $1 AND c.kind = 'group'""",
        code,
    )
    if not row:
        raise HTTPException(404, "This invite link isn't valid any more — ask for a new one.")
    return row


@router.get("/api/invite/{code}")
async def invite_preview(code: str, user_id: str = Depends(require_auth)):
    g = await _by_code(code)
    member = await one("SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2", g["id"], user_id)
    pending = await one("SELECT 1 FROM group_join_requests WHERE conversation_id = $1 AND user_id = $2", g["id"], user_id)
    return {"group": {"id": g["id"], "title": g["title"], "description": g["description"] or "",
                      "avatarColor": g["avatar_color"], "memberCount": g["members"],
                      "isMember": bool(member), "requested": bool(pending)}}


async def _queue_request(conversation_id: str, user_id: str):
    if await one("SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2", conversation_id, user_id):
        raise HTTPException(400, "You're already in this group.")
    await execute(
        "INSERT INTO group_join_requests (conversation_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        conversation_id, user_id,
    )
    who = await one("SELECT id, username, display_name, avatar_color, photo_path FROM users WHERE id = $1", user_id)
    admins = await query(
        "SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND role IN ('owner', 'admin')",
        conversation_id,
    )
    for a in admins:
        await hub.notify_user(a["user_id"], {"type": "join-request", "conversationId": conversation_id, "user": _user(who)})


@router.post("/api/invite/{code}/request")
async def request_join(code: str, user_id: str = Depends(require_auth)):
    g = await _by_code(code)
    await _queue_request(g["id"], user_id)
    return {"requested": True, "conversationId": g["id"]}


@router.delete("/api/conversations/{conversation_id}/join-request")
async def cancel_request(conversation_id: str, user_id: str = Depends(require_auth)):
    await execute("DELETE FROM group_join_requests WHERE conversation_id = $1 AND user_id = $2", conversation_id, user_id)
    return {"requested": False}


@router.post("/api/conversations/{conversation_id}/join-request")
async def request_community_group(conversation_id: str, user_id: str = Depends(require_auth)):
    """Ask to join a group of a community you're in (no invite link needed)."""
    ok = await one(
        """SELECT 1 FROM conversations g
             JOIN conversations a ON a.community_id = g.community_id AND a.is_announcement
             JOIN conversation_members cm ON cm.conversation_id = a.id AND cm.user_id = $2
            WHERE g.id = $1 AND g.community_id IS NOT NULL""",
        conversation_id, user_id,
    )
    if not ok:
        raise HTTPException(403, "You need an invite link to join this group.")
    await _queue_request(conversation_id, user_id)
    return {"requested": True}


@router.get("/api/conversations/{conversation_id}/join-requests")
async def list_requests(conversation_id: str, user_id: str = Depends(require_auth)):
    await require_group_admin(conversation_id, user_id)
    rows = await query(
        """SELECT u.id, u.username, u.display_name, u.avatar_color, u.photo_path, u.public_key, jr.created_at
             FROM group_join_requests jr JOIN users u ON u.id = jr.user_id
            WHERE jr.conversation_id = $1 ORDER BY jr.created_at""",
        conversation_id,
    )
    return {"requests": [{**_user(r), "requestedAt": r["created_at"]} for r in rows]}


@router.post("/api/conversations/{conversation_id}/join-requests/{target_id}/decline")
async def decline_request(conversation_id: str, target_id: str, user_id: str = Depends(require_auth)):
    await require_group_admin(conversation_id, user_id)
    await execute("DELETE FROM group_join_requests WHERE conversation_id = $1 AND user_id = $2", conversation_id, target_id)
    title = await one("SELECT title FROM conversations WHERE id = $1", conversation_id)
    await hub.notify_user(target_id, {"type": "join-declined", "conversationId": conversation_id, "title": title["title"]})
    return {"ok": True}


# ── Communities ──────────────────────────────────────────────

async def _community(community_id: str) -> dict:
    row = await one("SELECT id, name, description, avatar_color, owner_id FROM communities WHERE id = $1", community_id)
    if not row:
        raise HTTPException(404, "No such community.")
    return row


async def _announcement_id(community_id: str) -> str | None:
    row = await one("SELECT id FROM conversations WHERE community_id = $1 AND is_announcement", community_id)
    return row["id"] if row else None


async def require_community_admin(community_id: str, user_id: str) -> dict:
    c = await _community(community_id)
    ann = await _announcement_id(community_id)
    if str(c["owner_id"]) != str(user_id) and (not ann or await role_of(ann, user_id) not in ("owner", "admin")):
        raise HTTPException(403, "Only community admins can do that.")
    return c


@router.post("/api/communities", status_code=201)
async def create_community(request: Request, user_id: str = Depends(require_auth)):
    """The app first creates the announcements group (a normal encrypted
    group), then turns it into a community with this call."""
    body = await request.json()
    name = str(body.get("name") or "").strip()[:80]
    ann_id = body.get("announcementConversationId")
    if not name:
        raise HTTPException(400, "A community needs a name.")
    if await role_of(ann_id, user_id) != "owner":
        raise HTTPException(403, "Create the announcements group first.")
    row = await one(
        "INSERT INTO communities (name, description, avatar_color, owner_id) VALUES ($1, $2, $3, $4) RETURNING id",
        name, str(body.get("description") or "").strip()[:500], body.get("avatarColor") or "#6C5CE7", user_id,
    )
    await execute(
        """UPDATE conversations SET community_id = $2, is_announcement = true, only_admins_send = true
            WHERE id = $1""",
        ann_id, row["id"],
    )
    for gid in body.get("groupIds") or []:
        if await role_of(gid, user_id) in ("owner", "admin"):
            await execute("UPDATE conversations SET community_id = $2 WHERE id = $1 AND NOT is_announcement", gid, row["id"])
    await notify_members(ann_id, {"type": "communities-changed"})
    return {"community": {"id": row["id"]}}


@router.get("/api/communities")
async def my_communities(user_id: str = Depends(require_auth)):
    comms = await query(
        """SELECT DISTINCT co.id, co.name, co.description, co.avatar_color, co.owner_id, co.created_at
             FROM communities co
             JOIN conversations c ON c.community_id = co.id
             JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = $1
            ORDER BY co.created_at""",
        user_id,
    )
    out = []
    for co in comms:
        groups = await query(
            """SELECT c.id, c.title, c.avatar_color, c.is_announcement,
                      (SELECT count(*) FROM conversation_members x WHERE x.conversation_id = c.id) AS members,
                      (SELECT role FROM conversation_members x WHERE x.conversation_id = c.id AND x.user_id = $2) AS my_role,
                      EXISTS (SELECT 1 FROM group_join_requests j WHERE j.conversation_id = c.id AND j.user_id = $2) AS requested
                 FROM conversations c WHERE c.community_id = $1
                ORDER BY c.is_announcement DESC, c.title""",
            co["id"], user_id,
        )
        ann = next((g for g in groups if g["is_announcement"]), None)
        is_admin = str(co["owner_id"]) == str(user_id) or (ann and ann["my_role"] in ("owner", "admin"))
        out.append({
            "id": co["id"], "name": co["name"], "description": co["description"] or "",
            "avatarColor": co["avatar_color"], "isAdmin": bool(is_admin),
            "groups": [{
                "id": g["id"], "title": g["title"], "avatarColor": g["avatar_color"],
                "isAnnouncement": g["is_announcement"], "memberCount": g["members"],
                "isMember": g["my_role"] is not None, "myRole": g["my_role"], "requested": g["requested"],
            } for g in groups],
        })
    return {"communities": out}


@router.patch("/api/communities/{community_id}")
async def edit_community(community_id: str, request: Request, user_id: str = Depends(require_auth)):
    await require_community_admin(community_id, user_id)
    body = await request.json()
    name = str(body.get("name") or "").strip()[:80]
    if not name:
        raise HTTPException(400, "A community needs a name.")
    await execute("UPDATE communities SET name = $2, description = $3 WHERE id = $1",
                  community_id, name, str(body.get("description") or "").strip()[:500])
    return {"ok": True}


@router.post("/api/communities/{community_id}/groups")
async def link_group(community_id: str, request: Request, user_id: str = Depends(require_auth)):
    await require_community_admin(community_id, user_id)
    gid = (await request.json()).get("conversationId")
    await require_group_admin(gid, user_id)
    other = await one("SELECT community_id FROM conversations WHERE id = $1", gid)
    if other["community_id"] and str(other["community_id"]) != str(community_id):
        raise HTTPException(400, "That group already belongs to another community.")
    await execute("UPDATE conversations SET community_id = $2 WHERE id = $1 AND NOT is_announcement", gid, community_id)
    ann = await _announcement_id(community_id)
    if ann:
        await notify_members(ann, {"type": "communities-changed"})
    await notify_members(gid, {"type": "communities-changed"})
    return {"ok": True}


@router.delete("/api/communities/{community_id}/groups/{gid}")
async def unlink_group(community_id: str, gid: str, user_id: str = Depends(require_auth)):
    await require_community_admin(community_id, user_id)
    await execute("UPDATE conversations SET community_id = NULL WHERE id = $1 AND community_id = $2 AND NOT is_announcement",
                  gid, community_id)
    await notify_members(gid, {"type": "communities-changed"})
    return {"ok": True}


@router.get("/api/communities/{community_id}/missing-members")
async def missing_members(community_id: str, user_id: str = Depends(require_auth)):
    """People in the community's groups who aren't in its announcements
    group yet — an admin's app adds them (it holds the group key)."""
    await require_community_admin(community_id, user_id)
    ann = await _announcement_id(community_id)
    rows = await query(
        """SELECT DISTINCT u.id, u.username, u.display_name, u.avatar_color, u.photo_path, u.public_key
             FROM conversations c
             JOIN conversation_members cm ON cm.conversation_id = c.id
             JOIN users u ON u.id = cm.user_id
            WHERE c.community_id = $1 AND NOT c.is_announcement
              AND NOT EXISTS (SELECT 1 FROM conversation_members a WHERE a.conversation_id = $2 AND a.user_id = u.id)""",
        community_id, ann,
    )
    return {"announcementId": ann, "members": [_user(r) for r in rows]}


@router.delete("/api/communities/{community_id}")
async def delete_community(community_id: str, user_id: str = Depends(require_auth)):
    c = await _community(community_id)
    if str(c["owner_id"]) != str(user_id):
        raise HTTPException(403, "Only the community's owner can delete it.")
    ann = await _announcement_id(community_id)
    # Groups carry on as ordinary groups.
    await execute("UPDATE conversations SET community_id = NULL, is_announcement = false WHERE community_id = $1", community_id)
    await execute("DELETE FROM communities WHERE id = $1", community_id)
    if ann:
        await notify_members(ann, {"type": "communities-changed"})
    return {"ok": True}
