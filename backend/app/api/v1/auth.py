"""Mirrors src/routes/auth.js."""
import random
import re

import bcrypt
from fastapi import APIRouter, Depends, HTTPException, Request, Response

from app.core.security import clear_session_cookie, require_auth, set_session_cookie, sign_session
from app.core.database import one, query
from app.utils.serializers import shape_user

router = APIRouter(prefix="/api/auth")

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

    lower = username.lower()
    taken = await one("SELECT 1 FROM users WHERE username_lower = $1", lower)
    if taken:
        raise HTTPException(409, "That username is already taken.")

    hash_ = bcrypt.hashpw(password.encode(), bcrypt.gensalt(12)).decode()
    color = random.choice(AVATAR_COLORS)

    user = await one(
        """INSERT INTO users (username, username_lower, display_name, password_hash,
                              avatar_color, public_key, enc_private_key)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           RETURNING id, username, display_name, avatar_color, about, appearance""",
        username, lower, (display_name or username).strip()[:60], hash_, color, public_key, enc_private_key,
    )

    set_session_cookie(response, sign_session(user["id"]), request)
    return {"user": shape_user(user)}


@router.post("/login")
async def login(request: Request, response: Response):
    body = await request.json()
    username = body.get("username")
    password = body.get("password")

    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, appearance,
                  password_hash, enc_private_key
             FROM users WHERE username_lower = $1""",
        str(username or "").lower(),
    )

    # Same message, and the compare only runs when a row exists — mirrors
    # auth.js's `row && await bcrypt.compare(...)` short-circuit exactly
    # (preserved as-is here rather than "fixed", per the plan's parity goal).
    ok = row and bcrypt.checkpw(str(password or "").encode(), row["password_hash"].encode())
    if not ok:
        raise HTTPException(401, "Wrong username or password.")

    await query("UPDATE users SET last_seen = now() WHERE id = $1", row["id"])
    set_session_cookie(response, sign_session(row["id"]), request)

    return {"user": shape_user(row), "encPrivateKey": row["enc_private_key"]}


@router.post("/logout")
async def logout(request: Request, response: Response):
    clear_session_cookie(response, request)
    return {"ok": True}


@router.get("/me")
async def get_me(request: Request, response: Response, uid: str = Depends(require_auth)):
    row = await one(
        """SELECT id, username, display_name, avatar_color, about, photo_path, appearance, enc_private_key
             FROM users WHERE id = $1""",
        uid,
    )
    if not row:
        raise HTTPException(401, "Not signed in")
    # Sliding session: both apps call /me every time they start, so renewing
    # the cookie here keeps a user signed in until they log out themselves,
    # instead of being thrown out SESSION_TTL after their original login.
    set_session_cookie(response, sign_session(uid), request)
    return {"user": shape_user(row), "encPrivateKey": row["enc_private_key"]}
