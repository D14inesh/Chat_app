"""Message and call notifications for people who aren't connected right now
(no open tab / app): sent as Web Push to the browsers they allowed.

Messages are end-to-end encrypted, so the server never knows the text — a
push says who sent it and what kind it is ("🎤 Voice message", "New
message"). An open tab or app shows the real text itself. Each person can
turn message and call notifications off (users.notify_messages / notify_calls)."""
import asyncio

from app.core.database import one, query

KIND_TEXT = {
    "text": "New message",
    "voice": "🎤 Voice message",
    "file": "📎 Photo, video or file",
    "location": "📍 Location",
    "contact": "👤 Contact",
    "poll": "📊 Poll",
    "product": "🛍️ Product",
}


async def _push(user_id, data: dict):
    from app.schedulers.reminders_scheduler import push_to_user

    try:
        await push_to_user(str(user_id), data)
    except Exception as err:  # noqa: BLE001 — a notification must never break sending
        print(f"[notify] push failed: {err!r}")


async def message(conversation_id, sender_id, kind: str, mention_all: bool, offline_ids: list):
    if not offline_ids:
        return
    convo = await one("SELECT kind, title FROM conversations WHERE id = $1", conversation_id)
    sender = await one("SELECT display_name FROM users WHERE id = $1", sender_id)
    if not convo or not sender:
        return
    rows = await query(
        """SELECT u.id, u.notify_messages, cm.archived,
                  (cm.muted AND (cm.muted_until IS NULL OR cm.muted_until > now())) AS muted,
                  (cm.locked OR ($3 = 'direct' AND u.private_lock)) AS hidden
             FROM conversation_members cm JOIN users u ON u.id = cm.user_id
            WHERE cm.conversation_id = $1 AND cm.user_id = ANY($2::uuid[])""",
        conversation_id, [str(i) for i in offline_ids], convo["kind"],
    )
    who = sender["display_name"]
    title = who if convo["kind"] == "direct" else f"{who} @ {convo['title'] or 'Group'}"
    body = KIND_TEXT.get(kind, "New message")
    if mention_all:
        body = f"@everyone · {body}"
    sends = []
    for r in rows:
        if not r["notify_messages"]:
            continue
        if (r["muted"] or r["archived"]) and not mention_all:
            continue
        hidden = r["hidden"]   # locked / private-PIN chats never show who or what
        sends.append(_push(r["id"], {
            "title": "Veyon Chat" if hidden else title,
            "body": "New message" if hidden else body,
            "tag": f"chat-{conversation_id}",
            "conversationId": str(conversation_id),
            "kind": "message",
        }))
    await asyncio.gather(*sends)


async def call(conversation_id, caller_id, callee_id, call_type: str):
    row = await one("SELECT notify_calls FROM users WHERE id = $1", callee_id)
    caller = await one("SELECT display_name FROM users WHERE id = $1", caller_id)
    if not row or not row["notify_calls"] or not caller:
        return
    await _push(callee_id, {
        "title": f"📞 Incoming {'video' if call_type == 'video' else 'voice'} call",
        "body": f"{caller['display_name']} is calling you",
        "tag": f"call-{conversation_id}",
        "conversationId": str(conversation_id),
        "kind": "call",
        "requireInteraction": True,
    })


def fire(coro):
    """Run in the background — sending a message never waits on push."""
    asyncio.get_running_loop().create_task(coro)
