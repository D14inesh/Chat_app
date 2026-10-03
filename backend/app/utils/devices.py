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


def client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else None
