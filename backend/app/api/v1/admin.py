"""Admin panel (website) + announcements.

Admins are set with `python make_admin.py <username>`. They can see usage,
suspend accounts, free a user's locked devices, make backups and send an
announcement to everyone. Message content stays end-to-end encrypted —
nothing here can read chats."""
import asyncio
import os
import time
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request

from app.core import config
from app.core.database import execute, one, query, row_count
from app.core.security import bump_session_epoch, require_auth
from app.utils.backup import list_backups, run_backup

router = APIRouter()

_storage_cache: dict = {"at": 0.0, "value": None}


async def require_admin(uid: str = Depends(require_auth)) -> str:
    row = await one("SELECT is_admin FROM users WHERE id = $1", uid)
    if not row or not row["is_admin"]:
        raise HTTPException(403, "Admins only.")
    return uid


def _folder_bytes(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


async def _storage() -> dict:
    if _storage_cache["value"] is None or time.time() - _storage_cache["at"] > 60:
        value = await asyncio.to_thread(lambda: {
            "uploads": _folder_bytes(config.UPLOAD_DIR),
            "avatars": _folder_bytes(config.AVATAR_DIR) + _folder_bytes(config.WALLPAPER_DIR),
            "backups": _folder_bytes(config.BACKUP_DIR),
        })
        _storage_cache.update(at=time.time(), value=value)
    return _storage_cache["value"]


@router.get("/api/admin/stats")
async def stats(_: str = Depends(require_admin)):
    from app.websocket import manager as hub

    row = await one(
        """SELECT (SELECT count(*) FROM users) AS users,
                  (SELECT count(*) FROM users WHERE email_verified_at IS NOT NULL) AS verified,
                  (SELECT count(*) FROM users WHERE disabled_at IS NOT NULL) AS disabled,
                  (SELECT count(*) FROM users WHERE created_at > now() - interval '7 days') AS new_week,
                  (SELECT count(*) FROM messages) AS messages,
                  (SELECT count(*) FROM messages WHERE created_at > now() - interval '24 hours') AS messages_day,
                  (SELECT count(*) FROM conversations WHERE kind = 'group') AS groups,
                  pg_database_size(current_database()) AS db_bytes"""
    )
    from app.core import health

    return {**{k: row[k] for k in row}, "online": len(hub.online_user_ids()),
            "storage": await _storage(), "backups": list_backups()[:7], "schemaError": health.schema_error}


@router.get("/api/admin/users")
async def list_users(q: str = "", offset: int = 0, _: str = Depends(require_admin)):
    from app.websocket import manager as hub

    like = f"%{q.strip().lower()}%"
    rows = await query(
        """SELECT u.id, u.username, u.display_name, u.avatar_color, u.photo_path, u.phone, u.email,
                  u.email_verified_at IS NOT NULL AS verified, u.is_admin, u.disabled_at, u.created_at, u.last_seen,
                  (SELECT count(*) FROM device_bindings b WHERE b.user_id = u.id) AS devices
             FROM users u
            WHERE $1 = '%%' OR u.username_lower LIKE $1 OR lower(u.display_name) LIKE $1
                  OR coalesce(u.phone, '') LIKE $1 OR lower(coalesce(u.email, '')) LIKE $1
            ORDER BY u.created_at DESC LIMIT 50 OFFSET $2""",
        like, max(0, offset),
    )
    online = set(hub.online_user_ids())
    return {"users": [{
        "id": r["id"], "username": r["username"], "displayName": r["display_name"],
        "avatarColor": r["avatar_color"], "photoUrl": f"/api/users/{r['id']}/photo" if r["photo_path"] else None,
        "phone": r["phone"], "email": r["email"], "verified": r["verified"], "isAdmin": r["is_admin"],
        "disabled": r["disabled_at"] is not None, "createdAt": r["created_at"], "lastSeen": r["last_seen"],
        "devices": r["devices"], "online": str(r["id"]) in online,
    } for r in rows]}


async def _target(user_id: str) -> dict:
    row = await one("SELECT id, username FROM users WHERE id = $1", user_id)
    if not row:
        raise HTTPException(404, "No such user.")
    return row


@router.post("/api/admin/users/{user_id}/disable")
async def set_disabled(user_id: str, request: Request, admin_id: str = Depends(require_admin)):
    from app.websocket import manager as hub

    body = await request.json()
    disabled = bool(body.get("disabled"))
    target = await _target(user_id)
    if str(target["id"]) == str(admin_id):
        raise HTTPException(400, "You can't suspend your own account.")
    await execute("UPDATE users SET disabled_at = CASE WHEN $2 THEN now() END WHERE id = $1", user_id, disabled)
    if disabled:
        # Every session ends at once — sockets close, old cookies stop working.
        epoch = await bump_session_epoch(user_id)
        await hub.close_sessions_older_than(user_id, epoch)
    return {"ok": True, "disabled": disabled}


@router.post("/api/admin/users/{user_id}/release-devices")
async def release_devices(user_id: str, _: str = Depends(require_admin)):
    await _target(user_id)
    status = await execute("DELETE FROM device_bindings WHERE user_id = $1", user_id)
    return {"released": row_count(status)}


@router.post("/api/admin/users/{user_id}/admin")
async def set_admin(user_id: str, request: Request, admin_id: str = Depends(require_admin)):
    body = await request.json()
    make = bool(body.get("admin"))
    target = await _target(user_id)
    if str(target["id"]) == str(admin_id) and not make:
        raise HTTPException(400, "You can't remove your own admin access.")
    await execute("UPDATE users SET is_admin = $2 WHERE id = $1", user_id, make)
    return {"ok": True, "isAdmin": make}


@router.post("/api/admin/backups")
async def backup_now(_: str = Depends(require_admin)):
    try:
        info = await run_backup()
    except RuntimeError as err:
        raise HTTPException(500, str(err))
    return {"backup": info, "backups": list_backups()[:7]}


# ── Announcements ────────────────────────────────────────────

def _shape(r: dict) -> dict:
    return {"id": r["id"], "title": r["title"], "body": r["body"], "createdAt": r["created_at"]}


@router.post("/api/admin/announcements", status_code=201)
async def announce(request: Request, background: BackgroundTasks, admin_id: str = Depends(require_admin)):
    from app.schedulers.reminders_scheduler import push_to_user
    from app.websocket import manager as hub

    body = await request.json()
    title = str(body.get("title") or "").strip()[:120]
    text = str(body.get("body") or "").strip()[:2000]
    if not title or not text:
        raise HTTPException(400, "Write a title and a message.")
    row = await one(
        "INSERT INTO announcements (title, body, created_by) VALUES ($1, $2, $3) RETURNING id, title, body, created_at",
        title, text, admin_id,
    )
    item = _shape(row)
    for uid in hub.online_user_ids():
        await hub.notify_user(uid, {"type": "announcement", "announcement": item})

    async def push_all():
        users = await query("SELECT DISTINCT user_id FROM push_subscriptions")
        for u in users:
            try:
                await push_to_user(u["user_id"], {"title": f"📢 {title}", "body": text[:180], "reminderId": f"ann-{row['id']}"})
            except Exception as err:  # noqa: BLE001
                print(f"[announce] push failed: {err!r}")

    background.add_task(push_all)
    return {"announcement": item}


@router.delete("/api/admin/announcements/{ann_id}")
async def delete_announcement(ann_id: int, _: str = Depends(require_admin)):
    await execute("DELETE FROM announcements WHERE id = $1", ann_id)
    return {"ok": True}


@router.get("/api/announcements")
async def announcements(uid: str = Depends(require_auth)):
    rows = await query("SELECT id, title, body, created_at FROM announcements ORDER BY created_at DESC LIMIT 30")
    seen = await one("SELECT announcements_seen_at FROM users WHERE id = $1", uid)
    unseen = sum(1 for r in rows if seen and r["created_at"] > seen["announcements_seen_at"])
    return {"announcements": [_shape(r) for r in rows], "unseen": unseen}


@router.post("/api/announcements/seen")
async def announcements_seen(uid: str = Depends(require_auth)):
    await execute("UPDATE users SET announcements_seen_at = now() WHERE id = $1", uid)
    return {"ok": True}
