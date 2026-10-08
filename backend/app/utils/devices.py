"""Turns a sign-in request into a short human device label for login alerts
("Chrome on Windows", "Veyon app on Android")."""
import re

from fastapi import Request


def device_label(request: Request) -> str:
    # The mobile app names itself (dio's own user agent says nothing useful).
    client = (request.headers.get("x-veyon-client") or "").strip()
    if client:
        return client[:60]

    ua = request.headers.get("user-agent") or ""
    if "Edg/" in ua:
        browser = "Edge"
    elif "OPR/" in ua or "Opera" in ua:
        browser = "Opera"
    elif "Firefox/" in ua:
        browser = "Firefox"
    elif "Chrome/" in ua:
        browser = "Chrome"
    elif "Safari/" in ua:
        browser = "Safari"
    elif ua.startswith("Dart/"):
        browser = "Veyon app"
    else:
        browser = "Browser"

    if "Android" in ua:
        system = "Android"
    elif re.search(r"iPhone|iPad|iOS", ua):
        system = "iPhone"
    elif "Windows" in ua:
        system = "Windows"
    elif "Mac OS X" in ua or "Macintosh" in ua:
        system = "Mac"
    elif "Linux" in ua:
        system = "Linux"
    else:
        system = ""
    return f"{browser} on {system}" if system else browser


DEVICE_COOKIE = "vesper_device"
_DEVICE_RE = re.compile(r"^[A-Za-z0-9:_-]{8,120}$")


def device_id(request: Request, response=None) -> str | None:
    """Which phone/computer this request comes from. The app sends its
    Android ID in a header; a browser gets a long-lived cookie (issued here
    on first sight when a response is given to set it on)."""
    header = (request.headers.get("x-veyon-device") or "").strip()
    if header and _DEVICE_RE.match(header):
        return header
    cookie = request.cookies.get(DEVICE_COOKIE)
    if cookie and _DEVICE_RE.match(cookie):
        return cookie
    if response is None:
        return None
    import secrets

    from app.core.config import COOKIE_SAMESITE

    new_id = "web:" + secrets.token_hex(24)
    response.set_cookie(
        key=DEVICE_COOKIE, value=new_id, httponly=True, samesite=COOKIE_SAMESITE,
        secure=COOKIE_SAMESITE == "none" or request.url.scheme == "https",
        max_age=10 * 365 * 86400, path="/",
    )
    return new_id


def is_phone(dev: str | None) -> bool:
    """The phone app sends its own device id; browsers get a "web:" cookie."""
    return bool(dev) and not dev.startswith("web:")


async def device_owner(dev: str | None) -> dict | None:
    """{user_id, username, display_name} owning this phone, or None.
    One account per device is for the phone app only — browsers are free."""
    if not is_phone(dev):
        return None
    from app.core.database import one

    return await one(
        """SELECT b.user_id, u.username, u.display_name FROM device_bindings b
             JOIN users u ON u.id = b.user_id WHERE b.device_id = $1""",
        dev,
    )


def device_taken_message(owner: dict) -> str:
    return (f"This device already belongs to @{owner['username']}. Only one account can be used on a "
            f"device — sign in as @{owner['username']}, or release this device from that account's "
            f"Security & logins first.")


async def bind_device(dev: str | None, user_id: str, label: str):
    if not is_phone(dev):
        return
    from app.core.database import query

    await query(
        """INSERT INTO device_bindings (device_id, user_id, label) VALUES ($1, $2, $3)
           ON CONFLICT (device_id) DO UPDATE SET last_seen = now(), label = EXCLUDED.label
           WHERE device_bindings.user_id = EXCLUDED.user_id""",
        dev, user_id, label,
    )


def client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else None
