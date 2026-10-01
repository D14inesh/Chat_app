"""Mirrors src/routes/voice.js. Memory-only — this is the browser's own
decrypted plaintext audio, forwarded straight to Whisper and never persisted
here; the encrypted voice-note blob in uploads/ is untouched."""
import httpx
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from app.core.security import require_auth
from app.core.config import WHISPER_URL

router = APIRouter(prefix="/api/voice", dependencies=[Depends(require_auth)])

MAX_VOICE_BYTES = 25 * 1024 * 1024


@router.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    data = await audio.read()  # read into memory explicitly — never let it spool to disk
    if len(data) > MAX_VOICE_BYTES:
        raise HTTPException(413, "Voice note is too large to transcribe.")

    files = {"audio": (audio.filename or "audio.webm", data, audio.content_type or "application/octet-stream")}

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            whisper_res = await client.post(f"{WHISPER_URL}/transcribe", files=files)
    except httpx.RequestError as err:
        return JSONResponse(status_code=502, content={
            "error": f"Could not reach the transcription service at {WHISPER_URL}. Is it running? ({err})",
        })

    try:
        decoded = whisper_res.json()
    except ValueError:
        decoded = None

    if whisper_res.status_code != 200 or not isinstance((decoded or {}).get("text"), str):
        status = whisper_res.status_code if whisper_res.status_code != 200 else 502
        return JSONResponse(status_code=status, content={
            "error": (decoded or {}).get("detail") or (decoded or {}).get("error") or "Unexpected response from the transcription service.",
        })

    return {"text": decoded["text"], "language": decoded.get("language")}
