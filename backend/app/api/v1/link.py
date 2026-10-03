"""Mirrors src/routes/link.js — QR-based passwordless device linking via
ECDH. A multi-state row (pending -> ready -> used, or deleted on
expiry/cancel); see the atomic conditional UPDATE in /complete below."""
import asyncio
import secrets
from datetime import datetime, timezone
from io import BytesIO

import bcrypt
import qrcode
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import StreamingResponse

from app.core.security import require_auth, session_epoch, set_session_cookie, sign_session
from app.core.database import execute, one, query, row_count
from app.utils.serializers import shape_user

router = APIRouter(prefix="/api/link")

# Unambiguous base32-ish alphabet (no 0/O/1/I) — this ends up in a QR and, as
# a fallback, gets typed by hand.
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def new_code(length: int = 8) -> str:
    return "".join(CODE_ALPHABET[b % len(CODE_ALPHABET)] for b in secrets.token_bytes(length))


def looks_like_ecdh_jwk(jwk) -> bool:
    return (
        isinstance(jwk, dict)
        and jwk.get("kty") == "EC" and jwk.get("crv") == "P-256"
        and isinstance(jwk.get("x"), str) and isinstance(jwk.get("y"), str)
    )


def sweep():
    """Opportunistic cleanup so stale rows don't accumulate — fire-and-forget,
    piggybacked on traffic rather than a cron job, same as link.js's sweep()."""
    async def _run():
        try:
            await query("DELETE FROM link_requests WHERE expires_at <= now()")
        except Exception:
            pass
    asyncio.create_task(_run())


@router.post("/start", status_code=201)
async def start_link(request: Request):
    sweep()
    body = await request.json()
    ephemeral_public_key = body.get("ephemeralPublicKey")
    device_secret = body.get("deviceSecret")

    if not looks_like_ecdh_jwk(ephemeral_public_key):
        raise HTTPException(400, "Bad ephemeral key.")
    if not isinstance(device_secret, str) or not (20 <= len(device_secret) <= 200):
        raise HTTPException(400, "Bad device secret.")

    # Cost 8 — deliberately lower than the password hash's cost 12, since
    # this is a short-lived throwaway secret, not a long-term credential.
    hash_ = bcrypt.hashpw(device_secret.encode(), bcrypt.gensalt(8)).decode()

    code = None
    for attempt in range(5):
        code = new_code()
        try:
            await query(
                "INSERT INTO link_requests (code, device_secret_hash, ephemeral_public_key) VALUES ($1, $2, $3)",
                code, hash_, ephemeral_public_key,
            )
            break
        except Exception:
            if attempt == 4:
                raise

    return {"code": code, "expiresInSeconds": 180}


@router.get("/qr")
async def link_qr(code: str = ""):
    code = code.upper().strip()
    row = await one("SELECT status FROM link_requests WHERE code = $1", code)
    if not row or row["status"] != "pending":
        raise HTTPException(404, "expired")

    img = qrcode.make(f"vesper:link:{code}", box_size=8, border=2)
    buf = BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/png")


@router.post("/claim")
async def claim_link(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    code = str(body.get("code") or "").upper().strip()

    row = await one("SELECT ephemeral_public_key, status, expires_at FROM link_requests WHERE code = $1", code)
    if not row or row["status"] != "pending" or row["expires_at"] <= datetime.now(timezone.utc):
        raise HTTPException(404, "That link code is invalid or has expired.")

    return {"ephemeralPublicKey": row["ephemeral_public_key"]}


@router.post("/complete")
async def complete_link(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    code = str(body.get("code") or "").upper().strip()
    wrapped_key = body.get("wrappedKey")
    wrapped_iv = body.get("wrappedIv")

    if not isinstance(wrapped_key, str) or not isinstance(wrapped_iv, str) or len(wrapped_key) > 20000 or len(wrapped_iv) > 500:
        raise HTTPException(400, "Bad sealed key.")

    status = await execute(
        """UPDATE link_requests
              SET user_id = $2, wrapped_key = $3, wrapped_iv = $4, status = 'ready'
            WHERE code = $1 AND status = 'pending' AND expires_at > now()""",
        code, user_id, wrapped_key, wrapped_iv,
    )
    if not row_count(status):
        raise HTTPException(404, "That link request is no longer valid.")

    return {"ok": True}


@router.post("/poll")
async def poll_link(request: Request, response: Response):
    sweep()
    body = await request.json()
    code = str(body.get("code") or "").upper().strip()
    device_secret = str(body.get("deviceSecret") or "")

    row = await one(
        "SELECT device_secret_hash, status, user_id, wrapped_key, wrapped_iv, expires_at FROM link_requests WHERE code = $1",
        code,
    )
    if not row:
        raise HTTPException(404, "expired")

    ok = bcrypt.checkpw(device_secret.encode(), row["device_secret_hash"].encode())
    if not ok:
        raise HTTPException(403, "forbidden")

    if row["expires_at"] <= datetime.now(timezone.utc):
        await query("DELETE FROM link_requests WHERE code = $1", code)
        raise HTTPException(404, "expired")

    if row["status"] != "ready":
        return {"status": "pending"}

    user = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, appearance, public_key
             FROM users WHERE id = $1""",
        row["user_id"],
    )
    if not user:
        await query("DELETE FROM link_requests WHERE code = $1", code)
        raise HTTPException(404, "expired")

    # One account per device, same as a password sign-in.
    from app.utils.devices import bind_device, device_id, device_label, device_owner, device_taken_message
    dev = device_id(request, response)
    owner = await device_owner(dev)
    if owner and str(owner["user_id"]) != str(user["id"]):
        await query("DELETE FROM link_requests WHERE code = $1", code)
        raise HTTPException(403, device_taken_message(owner))
    await bind_device(dev, user["id"], device_label(request))

    # Single use — burn it now that we're handing over the goods.
    await query("UPDATE link_requests SET status = 'used' WHERE code = $1", code)
    await query("UPDATE users SET last_seen = now() WHERE id = $1", user["id"])

    set_session_cookie(response, sign_session(user["id"], await session_epoch(user["id"])), request)
    from app.api.v1.auth import record_login
    await record_login(user["id"], request, "qr")
    return {
        "status": "ready",
        "wrappedKey": row["wrapped_key"],
        "wrappedIv": row["wrapped_iv"],
        "publicKey": user["public_key"],
        "user": shape_user(user),
    }


@router.post("/cancel")
async def cancel_link(request: Request):
    body = await request.json()
    code = str(body.get("code") or "").upper().strip()
    await query("DELETE FROM link_requests WHERE code = $1 AND status <> 'ready'", code)
    return {"ok": True}
