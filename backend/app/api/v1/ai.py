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
