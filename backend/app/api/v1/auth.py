"""Mirrors src/routes/auth.js."""
import asyncio
import random
import re
import time

import asyncpg
import bcrypt
import jwt as pyjwt
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response

from app.core.security import (
    bump_session_epoch, clear_session_cookie, require_auth, session_epoch,
    set_session_cookie, sign_session,
)
from app.core.config import JWT_SECRET
from app.core.database import one, query
from app.utils.devices import (
    bind_device, client_ip, device_id, device_label, device_owner, device_taken_message,
)
from app.utils.age import is_adult, parse_birth_date
from app.utils.otp import check_code, ensure_contact_free, normalize_phone, read_contact, send_code
from app.utils.serializers import shape_user

router = APIRouter(prefix="/api/auth")


async def record_login(user_id: str, request: Request, method: str = "password"):
    """Logs a sign-in and alerts the user's other devices: live on every open
    socket, plus a Web Push notification where they've allowed it."""
    from app.schedulers.reminders_scheduler import push_to_user
    from app.websocket import manager as hub

    device = device_label(request)
    row = await one(
        """INSERT INTO login_events (user_id, device, ip, method) VALUES ($1, $2, $3, $4)
           RETURNING id, device, ip, method, created_at""",
        user_id, device, client_ip(request), method,
    )
    event = shape_login(row)
    await hub.notify_user(user_id, {"type": "login-alert", "login": event})
    try:
        await push_to_user(user_id, {
            "title": "🔐 New login to your account",
            "body": f"{device} just signed in. If this wasn't you, open Devices and log out all other devices.",
            "reminderId": f"login-{row['id']}",
        })
    except Exception as err:  # noqa: BLE001 — an alert must never block the login itself
        print(f"[login-alert] push failed: {err!r}")


def shape_login(r: dict) -> dict:
    return {"id": r["id"], "device": r["device"], "ip": r["ip"], "method": r["method"], "createdAt": r["created_at"]}

USERNAME_RE = re.compile(r"^[a-z0-9_.]{3,24}$", re.IGNORECASE)

AVATAR_COLORS = [
    "#6C5CE7", "#00B894", "#E17055", "#0984E3",
    "#E84393", "#FDCB6E", "#00CEC9", "#A29BFE",
]


@router.post("/register", status_code=201)
async def register(request: Request, response: Response):
    body = await request.json()
    username = body.get("username")
    display_name = body.get("displayName")
    password = body.get("password")
    public_key = body.get("publicKey")
    enc_private_key = body.get("encPrivateKey")

    if not username or not USERNAME_RE.match(username):
        raise HTTPException(400, "Username must be 3–24 letters, numbers, dot or underscore.")
    if not isinstance(password, str) or len(password) < 8:
        raise HTTPException(400, "Password must be at least 8 characters.")
    if not public_key or not enc_private_key:
        raise HTTPException(400, "Missing encryption keys.")

    # One account per device — a device that already has one can't make another.
    dev = device_id(request, response)
    owner = await device_owner(dev)
    if owner:
        raise HTTPException(403, device_taken_message(owner))

    lower = username.lower()
    taken = await one("SELECT 1 FROM users WHERE username_lower = $1", lower)
    if taken:
        raise HTTPException(409, "That username is already taken.")

    # One account per mobile number and per email; the email code proves the Gmail.
    birth = parse_birth_date(body.get("birthDate"))
    phone, email = read_contact(body)
    await ensure_contact_free(phone, email)
    await check_code(phone, email, "register", body.get("otp"))

    hash_ = bcrypt.hashpw(password.encode(), bcrypt.gensalt(12)).decode()
    color = random.choice(AVATAR_COLORS)

    try:
        user = await one(
            """INSERT INTO users (username, username_lower, display_name, password_hash,
                                  avatar_color, public_key, enc_private_key, phone, email, email_verified_at, birth_date)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), $10)
               RETURNING id, username, display_name, avatar_color, about, appearance""",
            username, lower, (display_name or username).strip()[:60], hash_, color, public_key, enc_private_key,
            phone, email, birth,
        )
    except asyncpg.UniqueViolationError:
        raise HTTPException(409, "That username, mobile number or email was just taken.")

    await bind_device(dev, user["id"], device_label(request))
    set_session_cookie(response, sign_session(user["id"], await session_epoch(user["id"])), request)
    await record_login(user["id"], request, "register")
    return {"user": with_contact(shape_user(user), {"phone": phone, "email": email, "email_verified_at": True, "birth_date": birth})}


@router.post("/login")
async def login(request: Request, response: Response):
    body = await request.json()
    username = body.get("username")
    password = body.get("password")

    # Sign in with username, mobile number or email.
    ident = str(username or "").strip().lower()
    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, appearance,
                  password_hash, enc_private_key, phone, email, email_verified_at,
                  enc_private_key_recovery, disabled_at, birth_date, private_lock
             FROM users WHERE username_lower = $1 OR phone = $2 OR lower(email) = $1
            ORDER BY (username_lower = $1) DESC LIMIT 1""",
        ident, normalize_phone(ident) or "",
    )

    # Same message, and the compare only runs when a row exists — mirrors
    # auth.js's `row && await bcrypt.compare(...)` short-circuit exactly
    # (preserved as-is here rather than "fixed", per the plan's parity goal).
    ok = row and bcrypt.checkpw(str(password or "").encode(), row["password_hash"].encode())
    if not ok:
        raise HTTPException(401, "Wrong username, number, email or password.")
    if row["disabled_at"]:
        raise HTTPException(403, "This account has been suspended by the admin.")

    # One account per device: this device may only sign in as its owner.
    dev = device_id(request, response)
    owner = await device_owner(dev)
    if owner and str(owner["user_id"]) != str(row["id"]):
        raise HTTPException(403, device_taken_message(owner))
    await bind_device(dev, row["id"], device_label(request))

    await query("UPDATE users SET last_seen = now() WHERE id = $1", row["id"])
    set_session_cookie(response, sign_session(row["id"], await session_epoch(row["id"])), request)
    await record_login(row["id"], request, "password")

    return {"user": with_contact(shape_user(row), row), "encPrivateKey": row["enc_private_key"]}


def with_contact(user: dict, row: dict) -> dict:
    """My own number/email — only ever on my own profile, never in
    shape_user, which other people see."""
    user["phone"] = row.get("phone")
    user["email"] = row.get("email")
    user["contactVerified"] = bool(row.get("phone") and row.get("email_verified_at"))
    user["hasRecoveryKey"] = bool(row.get("enc_private_key_recovery"))
    birth = row.get("birth_date")
    user["birthDate"] = birth.isoformat() if birth else None
    # 1-to-1 chats and calls are for 18+ (see utils/age.py).
    user["isAdult"] = is_adult(birth)
    user["privateLock"] = bool(row.get("private_lock"))
    return user


@router.post("/logout")
async def logout(request: Request, response: Response):
    clear_session_cookie(response, request)
    return {"ok": True}


@router.get("/me")
async def get_me(request: Request, response: Response, uid: str = Depends(require_auth)):
    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, appearance, enc_private_key, business,
                  phone, email, email_verified_at, enc_private_key_recovery, disabled_at,
                  birth_date, private_lock
             FROM users WHERE id = $1""",
        uid,
    )
    if not row:
        raise HTTPException(401, "Not signed in")
    if row["disabled_at"]:
        clear_session_cookie(response, request)
        raise HTTPException(401, "This account has been suspended by the admin.")

    # Sessions from before the one-account rule: the first account seen on
    # a device claims it; a second account's session there is ended.
    dev = device_id(request, response)
    owner = await device_owner(dev)
    if owner and str(owner["user_id"]) != str(uid):
        clear_session_cookie(response, request)
        raise HTTPException(401, device_taken_message(owner))
    await bind_device(dev, uid, device_label(request))

    user = shape_user(row)
    user["businessSettings"] = row["business"] or {}
    user["deviceLocked"] = bool(dev)
    with_contact(user, row)
    # Sliding session: both apps call /me every time they start, so renewing
    # the cookie here keeps a user signed in until they log out themselves,
    # instead of being thrown out SESSION_TTL after their original login.
    set_session_cookie(response, sign_session(uid, await session_epoch(uid)), request)
    return {"user": user, "encPrivateKey": row["enc_private_key"]}


@router.post("/birth-date")
async def set_birth_date(request: Request, uid: str = Depends(require_auth)):
    """Accounts made before the age rule add their date of birth — once."""
    birth = parse_birth_date((await request.json()).get("birthDate"))
    row = await one(
        "UPDATE users SET birth_date = $2 WHERE id = $1 AND birth_date IS NULL RETURNING birth_date", uid, birth,
    )
    if not row:
        raise HTTPException(400, "Your date of birth is already saved and can't be changed.")
    return {"birthDate": birth.isoformat(), "isAdult": is_adult(birth)}


@router.post("/recovery-key")
async def save_recovery_key(request: Request, uid: str = Depends(require_auth)):
    """Stores my private key wrapped with my recovery key (done in the app —
    the server never sees the recovery key or the private key)."""
    body = await request.json()
    wrapped = body.get("encPrivateKeyRecovery")
    if not isinstance(wrapped, dict) or not wrapped:
        raise HTTPException(400, "Missing recovery data.")
    await query("UPDATE users SET enc_private_key_recovery = $2 WHERE id = $1", uid, wrapped)
    return {"ok": True}


# ── Forgot password ───────────────────────────────────────────
# 1. /reset/otp     emails a code to the account's verified Gmail
# 2. /reset/verify  checks the code -> a 15-minute reset token, plus the
#                   recovery-wrapped key if the user saved a recovery key
# 3. /reset/complete sets the new password and the key wrapped with it
#    (the same key re-wrapped when the recovery key was given — old chats
#    stay readable — or a brand-new key when it wasn't). Every device is
#    signed out.

async def _reset_target(ident) -> dict:
    ident = str(ident or "").strip().lower()
    row = await one(
        """SELECT id, username, phone, email, email_verified_at, enc_private_key_recovery, disabled_at
             FROM users WHERE username_lower = $1 OR phone = $2 OR lower(email) = $1
            ORDER BY (username_lower = $1) DESC LIMIT 1""",
        ident, normalize_phone(ident) or "",
    )
    if not row:
        raise HTTPException(404, "No account with that username, mobile number or Gmail.")
    if row["disabled_at"]:
        raise HTTPException(403, "This account has been suspended by the admin.")
    if not (row["phone"] and row["email"] and row["email_verified_at"]):
        raise HTTPException(400, "This account has no verified Gmail, so its password can't be reset by code. Use your recovery key instead.")
    return row


def _mask_email(email: str) -> str:
    name, _, domain = email.partition("@")
    return (name[:2] + "•" * max(1, len(name) - 2)) + "@" + domain


@router.post("/reset/otp")
async def reset_send_code(request: Request):
    body = await request.json()
    row = await _reset_target(body.get("ident"))
    res = await send_code(row["phone"], row["email"], "reset")
    return {**res, "email": _mask_email(row["email"])}


@router.post("/reset/verify")
async def reset_verify(request: Request):
    body = await request.json()
    row = await _reset_target(body.get("ident"))
    await check_code(row["phone"], row["email"], "reset", body.get("otp"))
    token = pyjwt.encode(
        {"sub": str(row["id"]), "purpose": "reset", "exp": int(time.time()) + 15 * 60},
        JWT_SECRET, algorithm="HS256",
    )
    return {"resetToken": token, "username": row["username"], "recoveryWrapped": row["enc_private_key_recovery"]}


@router.post("/reset/complete")
async def reset_complete(request: Request):
    from app.websocket import manager as hub

    body = await request.json()
    try:
        claims = pyjwt.decode(str(body.get("resetToken") or ""), JWT_SECRET, algorithms=["HS256"])
    except pyjwt.PyJWTError:
        raise HTTPException(400, "This reset has expired — start again.")
    if claims.get("purpose") != "reset":
        raise HTTPException(400, "This reset has expired — start again.")
    uid = claims["sub"]
    password = body.get("password")
    enc_private_key = body.get("encPrivateKey")
    new_identity = bool(body.get("newIdentity"))
    public_key = body.get("publicKey")
    if not isinstance(password, str) or len(password) < 8:
        raise HTTPException(400, "Password must be at least 8 characters.")
    if not isinstance(enc_private_key, dict) or (new_identity and not isinstance(public_key, dict)):
        raise HTTPException(400, "Missing encryption keys.")

    hash_ = bcrypt.hashpw(password.encode(), bcrypt.gensalt(12)).decode()
    if new_identity:
        # A new key can't open anything wrapped for the old one, so the old
        # recovery data goes too.
        await query(
            """UPDATE users SET password_hash = $2, enc_private_key = $3, public_key = $4,
                                enc_private_key_recovery = NULL WHERE id = $1""",
            uid, hash_, enc_private_key, public_key,
        )
    else:
        await query("UPDATE users SET password_hash = $2, enc_private_key = $3 WHERE id = $1",
                    uid, hash_, enc_private_key)
    epoch = await bump_session_epoch(uid)
    await hub.close_sessions_older_than(uid, epoch)
    return {"ok": True}


@router.post("/otp")
async def send_signup_code(request: Request):
    """Sign-up step 1: emails a code for this mobile number + email."""
    body = await request.json()
    phone, email = read_contact(body)
    await ensure_contact_free(phone, email)
    return await send_code(phone, email, "register")


@router.post("/contact/otp")
async def send_contact_code(request: Request, uid: str = Depends(require_auth)):
    """Accounts made before verification: email a code to add number + email."""
    body = await request.json()
    phone, email = read_contact(body)
    await ensure_contact_free(phone, email, except_user=uid)
    return await send_code(phone, email, "contact")


@router.post("/contact")
async def save_contact(request: Request, uid: str = Depends(require_auth)):
    body = await request.json()
    phone, email = read_contact(body)
    await ensure_contact_free(phone, email, except_user=uid)
    await check_code(phone, email, "contact", body.get("otp"))
    try:
        await query("UPDATE users SET phone = $2, email = $3, email_verified_at = now() WHERE id = $1",
                    uid, phone, email)
    except asyncpg.UniqueViolationError:
        raise HTTPException(409, "That mobile number or email was just taken by another account.")
    return {"phone": phone, "email": email, "contactVerified": True}


@router.post("/device/release")
async def release_device(request: Request, response: Response, uid: str = Depends(require_auth)):
    """Frees THIS device from my account (e.g. before selling a phone) and
    signs it out, so a different account can be used on it next. Signing
    out is part of it: staying signed in would just claim the device again."""
    dev = device_id(request)
    if dev:
        await query("DELETE FROM device_bindings WHERE device_id = $1 AND user_id = $2", dev, uid)
    clear_session_cookie(response, request)
    return {"ok": True}


@router.get("/devices")
async def my_devices(uid: str = Depends(require_auth)):
    """The phones/computers locked to my account."""
    rows = await query(
        "SELECT device_id, label, created_at, last_seen FROM device_bindings WHERE user_id = $1 ORDER BY last_seen DESC",
        uid,
    )
    return {"devices": [{"label": r["label"] or "Device", "kind": r["device_id"].split(":")[0],
                         "since": r["created_at"], "lastSeen": r["last_seen"]} for r in rows]}


@router.get("/logins")
async def recent_logins(uid: str = Depends(require_auth)):
    """Recent sign-ins for the Devices screen."""
    rows = await query(
        """SELECT id, device, ip, method, created_at FROM login_events
            WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20""",
        uid,
    )
    return {"logins": [shape_login(r) for r in rows]}


@router.post("/logout-others")
async def logout_others(request: Request, response: Response, background: BackgroundTasks,
                        uid: str = Depends(require_auth)):
    """Signs out every other device: bumps the session epoch (so every older
    token stops working), gives THIS device a fresh token, and closes all
    live connections — this device reconnects with its new token, the
    others are refused and land on the login screen. The sockets close
    only after this reply (carrying the new cookie) has gone out, so the
    asking device never checks in with its old one."""
    from app.websocket import manager as hub

    new_epoch = await bump_session_epoch(uid)
    set_session_cookie(response, sign_session(uid, new_epoch), request)

    async def close_later():
        await asyncio.sleep(0.5)
        await hub.close_sessions_older_than(uid, new_epoch)

    background.add_task(close_later)
    return {"ok": True}
