"""Mirrors src/routes/gif.js — Tenor search/proxy. The /fetch host allowlist
is an SSRF guard on an authenticated-but-otherwise-open proxy endpoint and
must not be loosened."""
import re
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException, Response

from app.core.security import require_auth
from app.core.config import TENOR_API_KEY

router = APIRouter(prefix="/api/gif", dependencies=[Depends(require_auth)])

TENOR = "https://tenor.googleapis.com/v2"
TENOR_HOST_RE = re.compile(r"(^|\.)tenor\.com$")
GOOGLEAPIS_HOST_RE = re.compile(r"(^|\.)googleapis\.com$")


@router.get("/config")
async def gif_config():
    return {"enabled": bool(TENOR_API_KEY)}


@router.get("/search")
async def gif_search(q: str = ""):
    if not TENOR_API_KEY:
        raise HTTPException(503, "GIF search is not configured on this server.")

    q = q.strip()
    params = {
        "key": TENOR_API_KEY, "client_key": "vesper-chat", "limit": "24",
        "media_filter": "tinygif,gif", "contentfilter": "medium",
    }
    endpoint = f"{TENOR}/search" if q else f"{TENOR}/featured"
    if q:
        params["q"] = q

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.get(endpoint, params=params)
        if r.status_code != 200:
            raise HTTPException(502, "GIF provider error.")
        data = r.json()
    except httpx.RequestError:
        raise HTTPException(502, "Could not reach the GIF provider.")

    results = []
    for g in data.get("results") or []:
        formats = g.get("media_formats") or {}
        full = formats.get("gif")
        tiny = formats.get("tinygif") or full
        item = {
            "id": g.get("id"),
            "description": g.get("content_description") or "GIF",
            "preview": (tiny or {}).get("url"),
            "url": (full or {}).get("url"),
            "dims": (full or {}).get("dims") or (tiny or {}).get("dims") or [200, 200],
        }
        if item["url"] and item["preview"]:
            results.append(item)

    return {"results": results}


@router.get("/fetch")
async def gif_fetch(url: str = ""):
    try:
        host = urlparse(url).hostname or ""
    except ValueError:
        raise HTTPException(400, "Bad URL.")
    if not host:
        raise HTTPException(400, "Bad URL.")
    if not TENOR_HOST_RE.search(host) and not GOOGLEAPIS_HOST_RE.search(host):
        raise HTTPException(400, "Only Tenor media is allowed.")

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.get(url)
        if r.status_code != 200:
            raise HTTPException(502, "Could not fetch GIF.")
        data = r.content
    except httpx.RequestError:
        raise HTTPException(502, "Could not fetch GIF.")

    if len(data) > 8 * 1024 * 1024:
        raise HTTPException(413, "GIF too large.")

    return Response(content=data, media_type="image/gif")
