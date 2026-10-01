"""JWT session cookie auth — mirrors src/auth.js exactly (same cookie name,
same claim shape, same expiry semantics)."""
import re

import jwt
from fastapi import Cookie, HTTPException, Request, Response

from app.core.config import COOKIE_SAMESITE, JWT_SECRET, SESSION_TTL

COOKIE_NAME = "vesper_session"

_DURATION_RE = re.compile(r"^(\d+)\s*([smhd])$", re.IGNORECASE)
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def _ttl_seconds(ttl: str | int) -> int:
    """Parses '7d' / '24h' / '30m' / '60s' / a plain number of seconds —
    the same shorthand jsonwebtoken's `expiresIn` accepts via the `ms` package."""
    if isinstance(ttl, int):
        return ttl
    m = _DURATION_RE.match(ttl.strip())
    if not m:
        return int(ttl)  # plain numeric string, seconds
    value, unit = m.groups()
    return int(value) * _UNIT_SECONDS[unit.lower()]


def sign_session(user_id: str) -> str:
    import time
    now = int(time.time())
    payload = {"sub": user_id, "iat": now, "exp": now + _ttl_seconds(SESSION_TTL)}
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def verify_session(token: str | None) -> str | None:
    """Returns the user id, or None if the token is missing/expired/forged."""
    if not token:
        return None
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        return payload.get("sub")
    except jwt.PyJWTError:
        return None


def set_session_cookie(response: Response, token: str, request: Request):
    # The app is reachable over both plain HTTP (localhost) and HTTPS (LAN, via
    # the self-signed cert) at once — hardcoding secure=True would silently
    # stop the browser from ever sending the cookie back on the http:// origin.
    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        httponly=True,
        samesite=COOKIE_SAMESITE,
        secure=_cookie_secure(request),
        # Same lifetime as the token inside it (was a hard-coded 7 days, so
        # the cookie vanished even when SESSION_TTL allowed longer).
        max_age=_ttl_seconds(SESSION_TTL),
        path="/",
    )


def clear_session_cookie(response: Response, request: Request):
    # Same attributes as when set — browsers ignore a cross-site Set-Cookie
    # that tries to overwrite a SameSite=None cookie without them.
    response.delete_cookie(
        COOKIE_NAME, path="/", httponly=True,
        samesite=COOKIE_SAMESITE, secure=_cookie_secure(request),
    )


def _cookie_secure(request: Request) -> bool:
    # SameSite=None is rejected by browsers unless the cookie is also Secure.
    return COOKIE_SAMESITE == "none" or request.url.scheme == "https"


async def require_auth(request: Request, vesper_session: str | None = Cookie(default=None)) -> str:
    """FastAPI dependency — 401s unless a valid session cookie is present.
    Use as: `user_id: str = Depends(require_auth)`."""
    user_id = verify_session(vesper_session)
    if not user_id:
        raise HTTPException(status_code=401, detail="Not signed in")
    return user_id


async def optional_auth(vesper_session: str | None = Cookie(default=None)) -> str | None:
    """Same lookup, but never raises — for the WebSocket upgrade handshake,
    which closes the socket itself (code 4001) instead of an HTTP 401."""
    return verify_session(vesper_session)
