"""Mirrors src/routes/ai.js — the one conversation the server can actually
read; see db/schema.sql's note on ai_messages for why it's plaintext by
design and kept in its own table, never `messages`."""
import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

from app.core.security import require_auth
from app.core.config import OLLAMA_MODEL, OLLAMA_URL
from app.core.database import one, query

router = APIRouter(prefix="/api/ai", dependencies=[Depends(require_auth)])

HISTORY_WINDOW = 20


def shape(r: dict) -> dict:
    return {"id": r["id"], "role": r["role"], "content": r["content"], "createdAt": r["created_at"]}


@router.get("/messages")
async def ai_messages(user_id: str = Depends(require_auth)):
    rows = await query(
        "SELECT id, role, content, created_at FROM ai_messages WHERE user_id = $1 ORDER BY created_at ASC",
        user_id,
    )
    return {"messages": [shape(r) for r in rows]}


@router.post("/message", status_code=201)
async def send_ai_message(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    content = str(body.get("content") or "").strip()
    if not content:
        raise HTTPException(400, "Message is empty.")
    if len(content) > 4000:
        raise HTTPException(400, "Message is too long.")

    user_row = await one(
        "INSERT INTO ai_messages (user_id, role, content) VALUES ($1, 'user', $2) RETURNING id, role, content, created_at",
        user_id, content,
    )

    history_rows = await query(
        "SELECT role, content FROM ai_messages WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2",
        user_id, HISTORY_WINDOW,
    )
    history = list(reversed(history_rows))  # pulled newest-first for the LIMIT; Ollama wants oldest-first

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            ollama_res = await client.post(
                OLLAMA_URL,
                json={"model": OLLAMA_MODEL, "messages": history, "stream": False},
            )
    except httpx.RequestError as err:
        return JSONResponse(status_code=502, content={
            "error": f"Could not reach Ollama at {OLLAMA_URL}. Is it installed and running? ({err})",
            "userMessage": shape(user_row),
        })

    try:
        decoded = ollama_res.json()
    except ValueError:
        decoded = None

    if ollama_res.status_code != 200 or not (decoded and decoded.get("message", {}).get("content")):
        status = ollama_res.status_code if ollama_res.status_code != 200 else 502
        return JSONResponse(status_code=status, content={
            "error": (decoded or {}).get("error", "Unexpected response from Ollama."),
            "userMessage": shape(user_row),
        })

    assistant_row = await one(
        "INSERT INTO ai_messages (user_id, role, content) VALUES ($1, 'assistant', $2) RETURNING id, role, content, created_at",
        user_id, decoded["message"]["content"],
    )

    return {"userMessage": shape(user_row), "assistantMessage": shape(assistant_row)}


# ─────────────────────────────────────────────────────────────
# One-shot helpers on chat text: summarize, translate, smart replies.
# The browser/app decrypts the messages itself and sends ONLY the text the
# user asked about — nothing is stored, and the UI says plainly that this
# text goes to the server's AI (it can't stay end-to-end encrypted).
# ─────────────────────────────────────────────────────────────
MAX_LINES = 150
MAX_CHARS = 12000


async def _ask(system: str, user: str, timeout: int = 90) -> str:
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            res = await client.post(OLLAMA_URL, json={
                "model": OLLAMA_MODEL, "stream": False,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            })
    except httpx.RequestError:
        raise HTTPException(502, "The AI isn't reachable right now. Is Ollama running on the server?")
    try:
        content = res.json().get("message", {}).get("content")
    except ValueError:
        content = None
    if res.status_code != 200 or not content:
        raise HTTPException(502, "The AI couldn't answer that right now.")
    return content.strip()


def _transcript(body: dict) -> str:
    lines = body.get("lines")
    if not isinstance(lines, list) or not lines:
        raise HTTPException(400, "Nothing to work with.")
    out = []
    for item in lines[-MAX_LINES:]:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "Someone")[:40]
        text = str(item.get("text") or "").strip()
        if text:
            out.append(f"{name}: {text}")
    text = "\n".join(out)[-MAX_CHARS:]
    if not text:
        raise HTTPException(400, "Nothing to work with.")
    return text


@router.post("/summarize")
async def summarize(request: Request):
    body = await request.json()
    transcript = _transcript(body)
    summary = await _ask(
        "You summarize chat conversations. Reply with a short summary: 3 to 6 bullet points "
        "starting with '• ', covering decisions, questions, plans, dates and who said what that matters. "
        "Be factual, use the same language as the chat, no introduction line.",
        transcript,
    )
    return {"summary": summary}


LANGUAGES = {
    "en": "English", "ta": "Tamil", "hi": "Hindi", "te": "Telugu", "ml": "Malayalam", "kn": "Kannada",
    "ar": "Arabic", "fr": "French", "es": "Spanish", "de": "German", "zh": "Chinese", "ja": "Japanese",
}


@router.post("/translate")
async def translate(request: Request):
    body = await request.json()
    text = str(body.get("text") or "").strip()[:4000]
    target = LANGUAGES.get(str(body.get("to") or "en"), "English")
    if not text:
        raise HTTPException(400, "Nothing to translate.")
    result = await _ask(
        f"Translate the user's message into {target}. Reply with the translation only — "
        "no quotes, no notes, no explanation. Keep emojis, names and numbers as they are.",
        text, timeout=60,
    )
    return {"translation": result, "to": target}


@router.post("/replies")
async def smart_replies(request: Request):
    body = await request.json()
    transcript = _transcript(body)
    me = str(body.get("me") or "Me")[:40]
    raw = await _ask(
        f"You suggest replies for {me} in a chat. Read the conversation and give exactly 3 short, "
        f"natural replies {me} could send next (each under 12 words, different in tone: e.g. agree, ask, decline). "
        "Use the chat's language. Output only the 3 replies, one per line, no numbering, no quotes.",
        transcript, timeout=60,
    )
    replies = []
    for line in raw.splitlines():
        line = line.strip().lstrip("-•*0123456789.) ").strip().strip('"').strip()
        if line and line not in replies:
            replies.append(line[:120])
    return {"replies": replies[:3]}
