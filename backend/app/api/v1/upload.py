"""Mirrors src/routes/upload.js — pure filesystem router, no DB. What arrives
here is already an AES-GCM blob the browser encrypted, so there's no original
extension to preserve and nothing meaningful to sniff; a random opaque name
also stops one user from guessing another's upload path."""
import os
import re
import secrets
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse

from app.core.security import require_auth
from app.core.config import MAX_UPLOAD_BYTES, UPLOAD_DIR
from app.core.database import one

router = APIRouter(prefix="/api/upload", dependencies=[Depends(require_auth)])

os.makedirs(UPLOAD_DIR, exist_ok=True)

NAME_RE = re.compile(r"^[a-f0-9]{48}\.bin$")


@router.post("")
async def upload_blob(blob: UploadFile = File(...)):
    data = await blob.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, f"File is too large (limit {MAX_UPLOAD_BYTES // 1024 // 1024} MB).")

    filename = f"{secrets.token_hex(24)}.bin"
    (Path(UPLOAD_DIR) / filename).write_bytes(data)
    return {"filePath": filename, "fileSize": len(data)}


@router.get("/{name}")
async def download_blob(name: str, user_id: str = Depends(require_auth)):
    # os.path.basename strips any ../ traversal attempt, same as path.basename in Node.
    safe_name = os.path.basename(name)
    if not NAME_RE.match(safe_name):
        raise HTTPException(400, "Bad file reference.")

    full = Path(UPLOAD_DIR) / safe_name
    if not full.exists():
        raise HTTPException(404, "Not found.")

    # A view-once photo/video is handed to each recipient only until they've
    # opened it once — after that the server refuses to send it again.
    opened = await one(
        """SELECT 1 FROM messages m
             JOIN message_opens o ON o.message_id = m.id AND o.user_id = $2
            WHERE m.file_path = $1 AND m.view_once""",
        safe_name, user_id,
    )
    if opened:
        raise HTTPException(410, "This view-once message was already opened.")

    return FileResponse(full, media_type="application/octet-stream")
