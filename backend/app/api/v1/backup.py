"""Chat backup — one password-locked backup per account, like WhatsApp's
end-to-end encrypted backup.

The device builds the backup, encrypts it with a key made from a backup
password (PBKDF2 → AES-GCM, see application/public/js/features/backup.js), and
uploads the opaque result. The password never reaches the server, so the
server can store the file but cannot read it."""
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from app.core.config import CHAT_BACKUP_DIR, MAX_UPLOAD_BYTES
from app.core.database import execute, one
from app.core.security import require_auth

router = APIRouter(prefix="/api/backup", dependencies=[Depends(require_auth)])

MAGIC = b"VBK1"


def _file_for(user_id: str) -> Path:
    # user_id comes from the session (a uuid), never from the request.
    return Path(CHAT_BACKUP_DIR) / f"{user_id}.bin"


def _shape(row):
    if not row:
        return None
    return {
        "size": row["size"],
        "messageCount": row["message_count"],
        "device": row["device"],
        "createdAt": row["created_at"].isoformat(),
    }


@router.get("")
async def backup_info(user_id: str = Depends(require_auth)):
    row = await one("SELECT size, message_count, device, created_at FROM chat_backups WHERE user_id = $1", user_id)
    if row and not _file_for(user_id).exists():
        row = None
    return {"backup": _shape(row)}


@router.put("")
async def save_backup(
    blob: UploadFile = File(...),
    messageCount: int = Form(0),
    device: str = Form(""),
    user_id: str = Depends(require_auth),
):
    data = await blob.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, f"Backup is too large (limit {MAX_UPLOAD_BYTES // 1024 // 1024} MB).")
    if not data.startswith(MAGIC):
        raise HTTPException(400, "Not a chat backup.")

    Path(CHAT_BACKUP_DIR).mkdir(parents=True, exist_ok=True)
    path = _file_for(user_id)
    tmp = path.with_suffix(".tmp")
    tmp.write_bytes(data)
    tmp.replace(path)  # the old backup stays intact until the new one is fully written

    row = await one(
        """INSERT INTO chat_backups (user_id, size, message_count, device, created_at)
           VALUES ($1, $2, $3, $4, now())
           ON CONFLICT (user_id) DO UPDATE
             SET size = EXCLUDED.size, message_count = EXCLUDED.message_count,
                 device = EXCLUDED.device, created_at = now()
           RETURNING size, message_count, device, created_at""",
        user_id, len(data), max(0, messageCount), device[:60],
    )
    return {"backup": _shape(row)}


@router.get("/data")
async def download_backup(user_id: str = Depends(require_auth)):
    path = _file_for(user_id)
    if not path.exists():
        raise HTTPException(404, "No backup yet.")
    return FileResponse(path, media_type="application/octet-stream")


@router.delete("")
async def delete_backup(user_id: str = Depends(require_auth)):
    _file_for(user_id).unlink(missing_ok=True)
    await execute("DELETE FROM chat_backups WHERE user_id = $1", user_id)
    return {"ok": True}
