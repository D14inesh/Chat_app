"""Mirrors src/routes/push.js."""
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.security import require_auth
from app.core.config import VAPID_PUBLIC_KEY
from app.core.database import one, query

router = APIRouter(prefix="/api/push")


@router.get("/vapid-public-key")
async def vapid_public_key():
    """No auth needed — the browser needs this before subscribe() can even
    run, i.e. before there's necessarily a logged-in session on a fresh tab."""
    return {"publicKey": VAPID_PUBLIC_KEY}


@router.post("/subscribe", status_code=201)
async def subscribe(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    sub = body.get("subscription") or {}
    endpoint = sub.get("endpoint")
    p256dh = (sub.get("keys") or {}).get("p256dh")
    auth = (sub.get("keys") or {}).get("auth")
    if not endpoint or not p256dh or not auth:
        raise HTTPException(400, "Incomplete push subscription.")

    await query(
        """INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (endpoint) DO UPDATE SET user_id = $1, p256dh = $3, auth = $4""",
        user_id, endpoint, p256dh, auth,
    )
    return {"ok": True}


@router.post("/unsubscribe")
async def unsubscribe(request: Request, user_id: str = Depends(require_auth)):
    body = await request.json()
    endpoint = body.get("endpoint")
    if endpoint:
        await query("DELETE FROM push_subscriptions WHERE endpoint = $1 AND user_id = $2", endpoint, user_id)
    return {"ok": True}


@router.get("/settings")
async def notification_settings(user_id: str = Depends(require_auth)):
    row = await one("SELECT notify_messages, notify_calls FROM users WHERE id = $1", user_id)
    return {"messages": row["notify_messages"], "calls": row["notify_calls"]}


@router.patch("/settings")
async def update_notification_settings(request: Request, user_id: str = Depends(require_auth)):
    """Message / call notifications on or off — for every device of mine."""
    body = await request.json()
    row = await one(
        """UPDATE users SET notify_messages = COALESCE($2, notify_messages),
                            notify_calls = COALESCE($3, notify_calls)
            WHERE id = $1 RETURNING notify_messages, notify_calls""",
        user_id,
        bool(body["messages"]) if "messages" in body else None,
        bool(body["calls"]) if "calls" in body else None,
    )
    return {"messages": row["notify_messages"], "calls": row["notify_calls"]}
