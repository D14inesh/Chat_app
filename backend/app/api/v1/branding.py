"""App name + logo the owner picks in the admin app (admin/). The admin app
writes storage/branding/; this just serves it, with no sign-in, so the
sign-in page can show it too."""
import json

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from app.core.config import STORAGE_DIR

router = APIRouter(prefix="/api/branding")

BRAND_DIR = STORAGE_DIR / "branding"
DEFAULT_NAME = "Veyon Chat"
MIME = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"}


def _read() -> dict:
    try:
        b = json.loads((BRAND_DIR / "brand.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        b = {}
    logo = b.get("logo")
    if logo not in ("logo.png", "logo.jpg", "logo.webp", "logo.gif") or not (BRAND_DIR / logo).is_file():
        logo = None
    return {"name": b.get("name") or DEFAULT_NAME, "logo": logo, "v": int(b.get("v") or 0)}


@router.get("")
async def get_branding():
    b = _read()
    return {"name": b["name"], "logoUrl": f"/api/branding/logo?v={b['v']}" if b["logo"] else None, "v": b["v"]}


@router.get("/logo")
async def get_logo():
    b = _read()
    if not b["logo"]:
        raise HTTPException(404, "No logo.")
    return FileResponse(BRAND_DIR / b["logo"], media_type=MIME[b["logo"].rsplit(".", 1)[-1]],
                        headers={"Cache-Control": "public, max-age=3600"})
