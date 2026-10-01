"""Mirrors src/routes/users.js."""
import os
import secrets
from pathlib import Path

import qrcode
import qrcode.image.pil  # noqa: F401 — registers the PIL image factory
from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, StreamingResponse

from app.core.security import require_auth
from app.core.config import AVATAR_DIR
from app.core.database import execute, one, query, row_count
from app.utils.serializers import shape_user

router = APIRouter(prefix="/api/users", dependencies=[Depends(require_auth)])

os.makedirs(AVATAR_DIR, exist_ok=True)

AVATAR_EXT_BY_MIME = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
MAX_AVATAR_BYTES = 5 * 1024 * 1024

APPEARANCE_OPTIONS = {
    # 'veyon' is the new brand default; 'plum' was already selectable in the
    # client's own PALETTE_META/APPEARANCE_ALLOWED but had been missing from
    # this server-side whitelist (a pre-existing gap between app.js and this
    # route, inherited unchanged from the original Node app) — closing it
    # here since it's directly adjacent to the list this change already touches.
    "palette": ["veyon", "aurora", "obsidian", "nord", "cyber", "plum"],
    "mode": ["dark", "light"],
    "structure": ["floating", "boxed"],
}
DEFAULT_APPEARANCE = {"palette": "veyon", "mode": "dark", "structure": "floating"}


@router.get("")
async def search_users(q: str = "", user_id: str = Depends(require_auth)):
    q = q.strip()
    if len(q) < 1:
        return {"users": []}
    rows = await query(
        """SELECT id, username, display_name, avatar_color, about, photo_path, last_seen, public_key
             FROM users
            WHERE id <> $1
              AND (username_lower LIKE $2 OR lower(display_name) LIKE $2)
            ORDER BY username_lower
            LIMIT 20""",
        user_id, f"%{q.lower()}%",
    )
    return {"users": [shape_user(r) for r in rows]}


@router.get("/me/qr")
async def my_qr(user_id: str = Depends(require_auth)):
    img = qrcode.make(f"vesper:user:{user_id}", box_size=8, border=2)
    from io import BytesIO
    buf = BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/png")


@router.post("/me/photo")
async def upload_photo(photo: UploadFile = File(...), user_id: str = Depends(require_auth)):
    ext = AVATAR_EXT_BY_MIME.get(photo.content_type)
    if not ext:
        raise HTTPException(400, "Please upload a JPEG, PNG, or WebP image (max 5 MB).")

    data = await photo.read()
    if len(data) > MAX_AVATAR_BYTES:
        raise HTTPException(413, "Photo is too large (limit 5 MB).")

    previous = await one("SELECT photo_path FROM users WHERE id = $1", user_id)
    filename = f"{secrets.token_hex(24)}{ext}"
    (Path(AVATAR_DIR) / filename).write_bytes(data)
    await query("UPDATE users SET photo_path = $1 WHERE id = $2", filename, user_id)

    if previous and previous["photo_path"]:
        (Path(AVATAR_DIR) / previous["photo_path"]).unlink(missing_ok=True)

    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, last_seen, public_key
             FROM users WHERE id = $1""",
        user_id,
    )
    return {"user": shape_user(row)}


@router.get("/{target_id}/photo")
async def get_photo(target_id: str):
    row = await one("SELECT photo_path FROM users WHERE id = $1", target_id)
    if not row or not row["photo_path"]:
        raise HTTPException(404, "No photo.")
    full = Path(AVATAR_DIR) / row["photo_path"]
    if not full.exists():
        raise HTTPException(404, "No photo.")
    return FileResponse(full)


@router.get("/me/blocked")
async def my_blocked(user_id: str = Depends(require_auth)):
    rows = await query(
        """SELECT u.id, u.username, u.display_name, u.avatar_color, u.about, u.photo_path, u.last_seen, u.public_key
             FROM blocked_users b
             JOIN users u ON u.id = b.blocked_id
            WHERE b.blocker_id = $1
            ORDER BY b.created_at DESC""",
        user_id,
    )
    return {"users": [shape_user(r) for r in rows]}


@router.patch("/me")
async def update_me(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    display_name = str(body.get("displayName") or "")[:60]
    about = str(body.get("about") or "")[:140]
    row = await one(
        """UPDATE users
              SET display_name = COALESCE(NULLIF(TRIM($2), ''), display_name),
                  about        = COALESCE(NULLIF(TRIM($3), ''), about)
            WHERE id = $1
            RETURNING id, username, display_name, avatar_color, about, photo_path, last_seen, public_key""",
        user_id, display_name, about,
    )
    return {"user": shape_user(row)}


@router.patch("/me/appearance")
async def update_appearance(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    current = await one("SELECT appearance FROM users WHERE id = $1", user_id)
    next_ = {**DEFAULT_APPEARANCE, **((current and current["appearance"]) or {})}

    for key, allowed in APPEARANCE_OPTIONS.items():
        value = body.get(key)
        if isinstance(value, str) and value in allowed:
            next_[key] = value
    if next_["palette"] == "cyber":
        next_["mode"] = "dark"  # neon has no light variant

    row = await one("UPDATE users SET appearance = $2 WHERE id = $1 RETURNING appearance", user_id, next_)
    return {"appearance": row["appearance"]}


@router.get("/{target_id}")
async def get_user(target_id: str, user_id: str = Depends(require_auth)):
    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, last_seen, public_key
             FROM users WHERE id = $1""",
        target_id,
    )
    if not row:
        raise HTTPException(404, "No such user.")

    you_blocked = await one("SELECT 1 FROM blocked_users WHERE blocker_id = $1 AND blocked_id = $2", user_id, target_id)
    blocked_you = await one("SELECT 1 FROM blocked_users WHERE blocker_id = $1 AND blocked_id = $2", target_id, user_id)

    return {"user": {**shape_user(row), "youBlocked": bool(you_blocked), "blockedYou": bool(blocked_you)}}


@router.post("/{target_id}/block", status_code=201)
async def block_user(target_id: str, user_id: str = Depends(require_auth)):
    if target_id == user_id:
        raise HTTPException(400, "You can't block yourself.")
    await query(
        "INSERT INTO blocked_users (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        user_id, target_id,
    )
    return {"blocked": True}


@router.delete("/{target_id}/block")
async def unblock_user(target_id: str, user_id: str = Depends(require_auth)):
    await query("DELETE FROM blocked_users WHERE blocker_id = $1 AND blocked_id = $2", user_id, target_id)
    return {"blocked": False}
