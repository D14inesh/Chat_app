"""WebSocket hub — mirrors src/ws/hub.js. Handles presence, typing, read
receipts, reactions, edit/delete, 1:1 WebRTC call signaling, group call
rooms, and live-game relay.

Connection liveness: the Node version manually pings every socket every 30s
and terminates non-answering ones (`ws.ping()`/`ws.on('pong')`). Here that's
delegated to uvicorn's underlying `websockets` implementation, which already
does transport-level ping/pong keepalive and drops dead connections on its
own (configured in main.py) — a WebSocketDisconnect on a dead socket reaches
the same on_close cleanup path either way. The separate JSON-level
`{"type": "ping"}` -> `{"type": "pong"}` handled in dispatch() below is a
distinct, additional app-level feature and is preserved as-is.
"""
import asyncio
import json
import uuid
from datetime import datetime, timezone

from fastapi import WebSocket, WebSocketDisconnect

from app.core.security import COOKIE_NAME, verify_session
from app.core.database import is_blocked_either_way, one, query, transaction
from app.utils.serializers import shape_message

# userId -> set[WebSocket] — a Set, not a single socket, so the same account
# open in several tabs/devices at once gets every event.
sockets: dict[str, set[WebSocket]] = {}

# conversationId -> {userId: WebSocket} — group call seat map. Guarded by
# _group_call_lock (see on_group_call_join) so the "who's here / evict my
# stale tab / take my seat" sequence is atomic even though, unlike Node,
# every send() here is itself an `await` and could otherwise interleave with
# another client's join arriving in between.
group_call_rooms: dict[str, dict[str, WebSocket]] = {}
_group_call_lock = asyncio.Lock()

GROUP_CALL_CAP = {"video": 4, "audio": 6}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json_default(o):
    # asyncpg returns timestamptz columns as timezone-aware datetime objects.
    # Starlette's WebSocket.send_json() uses plain json.dumps() under the
    # hood (unlike a FastAPI REST response, which goes through
    # jsonable_encoder and handles this automatically) — so every payload
    # here that carries a raw created_at/delivered_at/read_at/etc. needs this
    # or it crashes the send with "Object of type datetime is not JSON
    # serializable". Formatted 'Z'-suffixed to match what a JS `Date` would
    # have produced via JSON.stringify on the old Node backend.
    if isinstance(o, datetime):
        return o.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    # asyncpg also returns every `uuid` column (id, senderId, conversationId,
    # userId, ...) as a uuid.UUID object, not a str — same "REST responses
    # are fine via jsonable_encoder, raw send_json is not" situation as datetime above.
    if isinstance(o, uuid.UUID):
        return str(o)
    raise TypeError(f"Object of type {type(o).__name__} is not JSON serializable")


async def send(ws: WebSocket, obj: dict):
    try:
        await ws.send_text(json.dumps(obj, default=_json_default))
    except Exception:
        pass  # socket already gone; caller doesn't need to know


async def fanout(user_id: str, obj: dict, except_ws: WebSocket | None = None):
    """Send to every socket a user has open, optionally skipping one."""
    conns = sockets.get(user_id)
    if not conns:
        return
    for ws in list(conns):
        if ws is not except_ws:
            await send(ws, obj)


def is_online(user_id: str) -> bool:
    return user_id in sockets


def online_user_ids() -> list[str]:
    return list(sockets.keys())


async def notify_user(user_id: str, obj: dict):
    """Lets REST routes (accept/decline, etc.) push a live WS event without
    reaching into this module's socket registry directly."""
    await fanout(user_id, obj)


async def handle_connection(websocket: WebSocket):
    token = websocket.cookies.get(COOKIE_NAME)
    user_id = verify_session(token)

    if not user_id:
        await websocket.close(code=4001, reason="Not signed in")
        return

    await websocket.accept()
    sockets.setdefault(user_id, set()).add(websocket)

    # First socket for this user = they just came online.
    if len(sockets[user_id]) == 1:
        await query("UPDATE users SET last_seen = now() WHERE id = $1", user_id)
        await broadcast_presence(user_id, True)

    await send(websocket, {"type": "ready", "userId": user_id})
    await flush_pending_deliveries(user_id)

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                await send(websocket, {"type": "error", "error": "Malformed frame"})
                continue

            try:
                await dispatch(websocket, user_id, msg)
            except Exception as err:  # noqa: BLE001 — one bad frame must not kill the connection
                print(f"[ws] handler failed: {err!r}")
                await send(websocket, {"type": "error", "error": "Something went wrong handling that."})
    except WebSocketDisconnect:
        pass
    finally:
        await leave_all_group_call_rooms(websocket, user_id)

        conns = sockets.get(user_id)
        if conns is not None:
            conns.discard(websocket)
            if not conns:
                del sockets[user_id]
                await query("UPDATE users SET last_seen = now() WHERE id = $1", user_id)
                await broadcast_presence(user_id, False)


# ─────────────────────────────────────────────────────────────
# Inbound frames
# ─────────────────────────────────────────────────────────────
async def dispatch(ws: WebSocket, user_id: str, msg: dict):
    t = msg.get("type")
    if t == "send":
        return await on_send(ws, user_id, msg)
    if t == "typing":
        return await on_typing(ws, user_id, msg)
    if t == "read":
        return await on_read(ws, user_id, msg)
    if t == "react":
        return await on_react(ws, user_id, msg)
    if t == "delete-message":
        return await on_delete_message(ws, user_id, msg)
    if t == "edit-message":
        return await on_edit_message(ws, user_id, msg)
    if t == "call-offer":
        return await on_call_offer(ws, user_id, msg)
    if t == "call-answer":
        return await on_call_answer(ws, user_id, msg)
    if t == "call-decline":
        return await on_call_decline(ws, user_id, msg)
    if t == "call-ice":
        return await on_call_ice(ws, user_id, msg)
    if t == "call-end":
        return await on_call_end(ws, user_id, msg)
    if t == "group-call-query":
        return await on_group_call_query(ws, user_id, msg)
    if t == "group-call-join":
        return await on_group_call_join(ws, user_id, msg)
    if t == "group-call-leave":
        return await on_group_call_leave(ws, user_id, msg)
    if t == "group-call-offer":
        return await relay_group_call_frame(ws, user_id, msg, "group-call-offer")
    if t == "group-call-answer":
        return await relay_group_call_frame(ws, user_id, msg, "group-call-answer")
    if t == "group-call-ice":
        return await relay_group_call_frame(ws, user_id, msg, "group-call-ice")
    if t == "game-signal":
        return await on_game_signal(ws, user_id, msg)
    if t == "ping":
        return await send(ws, {"type": "pong"})
    return await send(ws, {"type": "error", "error": f"Unknown type: {t}"})


async def on_send(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    ciphertext = msg.get("ciphertext")
    iv = msg.get("iv")
    kind = msg.get("kind", "text")
    file_path = msg.get("filePath")
    file_size = msg.get("fileSize")
    temp_id = msg.get("tempId")
    reply_to_id = msg.get("replyToId")

    if not conversation_id or not ciphertext or not iv:
        return await send(ws, {"type": "error", "error": "Missing message fields", "tempId": temp_id})
    if kind not in ("text", "file", "voice", "location", "contact"):
        return await send(ws, {"type": "error", "error": "Bad message kind", "tempId": temp_id})

    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return await send(ws, {"type": "error", "error": "Not your conversation.", "tempId": temp_id})
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Accept the request before you can reply.", "tempId": temp_id})
    if ctx["kind"] == "direct":
        other_id = next((i for i in ctx["memberIds"] if i != user_id), None)
        if other_id and await is_blocked_either_way(user_id, other_id):
            return await send(ws, {"type": "error", "error": "You can no longer message this person.", "tempId": temp_id})

    valid_reply_to_id = None
    if reply_to_id:
        target = await one(
            "SELECT 1 FROM messages WHERE id = $1 AND conversation_id = $2", reply_to_id, conversation_id
        )
        if target:
            valid_reply_to_id = reply_to_id

    recipients = [i for i in ctx["memberIds"] if i != user_id]

    async with transaction() as conn:
        row = await conn.fetchrow(
            """INSERT INTO messages (conversation_id, sender_id, kind, ciphertext, iv, file_path, file_size, reply_to_id)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
               RETURNING id, sender_id, kind, ciphertext, iv, file_path, file_size, created_at, reply_to_id""",
            conversation_id, user_id, kind, ciphertext, iv, file_path, file_size, valid_reply_to_id,
        )
        row = dict(row)
        for rid in recipients:
            await conn.execute(
                "INSERT INTO message_receipts (message_id, user_id, delivered_at) VALUES ($1, $2, $3)",
                row["id"], rid, datetime.now(timezone.utc) if rid in sockets else None,
            )

    payload = shape_message(row)

    await send(ws, {"type": "sent", "tempId": temp_id, "message": payload, "conversationId": conversation_id})
    for rid in recipients:
        await fanout(rid, {"type": "message", "conversationId": conversation_id, "message": payload})
    await fanout(user_id, {"type": "message", "conversationId": conversation_id, "message": payload}, ws)


async def on_typing(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    if not conversation_id:
        return
    members = await member_ids(conversation_id)
    if user_id not in members:
        return
    for rid in members:
        if rid != user_id:
            await fanout(rid, {
                "type": "typing", "conversationId": conversation_id,
                "userId": user_id, "isTyping": bool(msg.get("isTyping")),
            })


async def on_read(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    if not conversation_id:
        return
    members = await member_ids(conversation_id)
    if user_id not in members:
        return

    rows = await query(
        """UPDATE message_receipts r
              SET read_at = now(), delivered_at = COALESCE(r.delivered_at, now())
             FROM messages m
            WHERE m.id = r.message_id
              AND m.conversation_id = $1
              AND r.user_id = $2
              AND r.read_at IS NULL
            RETURNING r.message_id, m.sender_id""",
        conversation_id, user_id,
    )
    if not rows:
        return

    await send(ws, {"type": "read-cleared", "conversationId": conversation_id})

    by_sender: dict[str, list] = {}
    for r in rows:
        by_sender.setdefault(r["sender_id"], []).append(r["message_id"])
    for sender_id, ids in by_sender.items():
        await fanout(sender_id, {"type": "receipts", "conversationId": conversation_id, "status": "read", "messageIds": ids})


async def on_react(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    ciphertext = msg.get("ciphertext")
    iv = msg.get("iv")
    remove = msg.get("remove")
    if not conversation_id or not message_id:
        return

    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Accept the request before you can react."})

    if remove:
        await query("DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2", message_id, user_id)
        for rid in ctx["memberIds"]:
            await fanout(rid, {"type": "reaction", "conversationId": conversation_id, "messageId": message_id, "userId": user_id, "removed": True})
        return

    if not ciphertext or not iv:
        return

    await query(
        """INSERT INTO message_reactions (message_id, user_id, ciphertext, iv)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (message_id, user_id) DO UPDATE
             SET ciphertext = EXCLUDED.ciphertext, iv = EXCLUDED.iv, created_at = now()""",
        message_id, user_id, ciphertext, iv,
    )
    for rid in ctx["memberIds"]:
        await fanout(rid, {"type": "reaction", "conversationId": conversation_id, "messageId": message_id, "userId": user_id, "ciphertext": ciphertext, "iv": iv})


async def on_delete_message(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    if not conversation_id or not message_id:
        return

    row = await one("SELECT sender_id FROM messages WHERE id = $1 AND conversation_id = $2", message_id, conversation_id)
    if not row or row["sender_id"] != user_id:
        return await send(ws, {"type": "error", "error": "You can only delete your own messages."})

    await query("UPDATE messages SET deleted_at = now() WHERE id = $1", message_id)

    for rid in await member_ids(conversation_id):
        await fanout(rid, {"type": "message-deleted", "conversationId": conversation_id, "messageId": message_id})


async def on_edit_message(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    ciphertext = msg.get("ciphertext")
    iv = msg.get("iv")
    if not conversation_id or not message_id or not ciphertext or not iv:
        return

    row = await one("SELECT sender_id, kind FROM messages WHERE id = $1 AND conversation_id = $2", message_id, conversation_id)
    if not row or row["sender_id"] != user_id:
        return await send(ws, {"type": "error", "error": "You can only edit your own messages."})
    if row["kind"] != "text":
        return await send(ws, {"type": "error", "error": "Only text messages can be edited."})

    updated = await one(
        "UPDATE messages SET ciphertext = $1, iv = $2, edited_at = now() WHERE id = $3 RETURNING edited_at",
        ciphertext, iv, message_id,
    )

    for rid in await member_ids(conversation_id):
        await fanout(rid, {
            "type": "message-edited", "conversationId": conversation_id, "messageId": message_id,
            "ciphertext": ciphertext, "iv": iv, "editedAt": updated["edited_at"],
        })


async def flush_pending_deliveries(user_id: str):
    rows = await query(
        """UPDATE message_receipts r
              SET delivered_at = now()
             FROM messages m
            WHERE m.id = r.message_id
              AND r.user_id = $1
              AND r.delivered_at IS NULL
            RETURNING r.message_id, m.sender_id, m.conversation_id""",
        user_id,
    )
    by_key: dict[tuple, list] = {}
    for r in rows:
        key = (r["sender_id"], r["conversation_id"])
        by_key.setdefault(key, []).append(r["message_id"])

    for (sender_id, conversation_id), ids in by_key.items():
        await fanout(sender_id, {"type": "receipts", "conversationId": conversation_id, "status": "delivered", "messageIds": ids})


async def broadcast_presence(user_id: str, online: bool):
    rows = await query(
        """SELECT DISTINCT other.user_id
             FROM conversation_members mine
             JOIN conversation_members other
               ON other.conversation_id = mine.conversation_id
              AND other.user_id <> mine.user_id
            WHERE mine.user_id = $1""",
        user_id,
    )
    for r in rows:
        await fanout(r["user_id"], {"type": "presence", "userId": user_id, "online": online, "lastSeen": _now_iso()})


# ─────────────────────────────────────────────────────────────
# Calling (WebRTC signaling relay — 1:1 direct conversations only)
# ─────────────────────────────────────────────────────────────
async def on_call_offer(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    call_type = msg.get("callType")
    sdp = msg.get("sdp")
    if not conversation_id or not to_user_id or not sdp or call_type not in ("audio", "video"):
        return

    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"] or to_user_id not in ctx["memberIds"]:
        return await send(ws, {"type": "call-error", "conversationId": conversation_id, "error": "Not your conversation."})
    if ctx["kind"] != "direct":
        return await send(ws, {"type": "call-error", "conversationId": conversation_id, "error": "Calling is only available in direct chats."})
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "call-error", "conversationId": conversation_id, "error": "Accept the request before you can call."})
    if await is_blocked_either_way(user_id, to_user_id):
        return await send(ws, {"type": "call-error", "conversationId": conversation_id, "error": "You can no longer call this person."})

    await fanout(to_user_id, {"type": "call-offer", "conversationId": conversation_id, "fromUserId": user_id, "callType": call_type, "sdp": sdp})
    await fanout(user_id, {"type": "call-started-elsewhere", "conversationId": conversation_id, "toUserId": to_user_id, "callType": call_type}, ws)


async def on_call_answer(ws: WebSocket, user_id: str, msg: dict):
    to_user_id = msg.get("toUserId")
    conversation_id = msg.get("conversationId")
    sdp = msg.get("sdp")
    if not conversation_id or not to_user_id or not sdp:
        return
    await fanout(to_user_id, {"type": "call-answer", "conversationId": conversation_id, "fromUserId": user_id, "sdp": sdp})
    await fanout(user_id, {"type": "call-claimed", "conversationId": conversation_id}, ws)


async def on_call_decline(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    if not conversation_id or not to_user_id:
        return
    await fanout(to_user_id, {"type": "call-decline", "conversationId": conversation_id, "fromUserId": user_id})
    await fanout(user_id, {"type": "call-claimed", "conversationId": conversation_id}, ws)


async def on_call_ice(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    candidate = msg.get("candidate")
    if not conversation_id or not to_user_id or not candidate:
        return
    await fanout(to_user_id, {"type": "call-ice", "conversationId": conversation_id, "fromUserId": user_id, "candidate": candidate})


async def on_call_end(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    if not conversation_id or not to_user_id:
        return
    await fanout(to_user_id, {"type": "call-end", "conversationId": conversation_id, "fromUserId": user_id})


# ─────────────────────────────────────────────────────────────
# Live games — one pass-through relay frame for every game.
# ─────────────────────────────────────────────────────────────
async def on_game_signal(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    data = msg.get("data")
    if not conversation_id or not to_user_id or not data:
        return

    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"] or to_user_id not in ctx["memberIds"]:
        return
    if ctx["kind"] != "direct":
        return
    if blocked_by_pending_request(ctx, user_id):
        return
    if await is_blocked_either_way(user_id, to_user_id):
        return

    await fanout(to_user_id, {"type": "game-signal", "conversationId": conversation_id, "fromUserId": user_id, "data": data})


# ─────────────────────────────────────────────────────────────
# Group calling — "start or join a room", not ring-and-accept.
# ─────────────────────────────────────────────────────────────
async def on_group_call_query(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    if not conversation_id:
        return
    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return
    room = group_call_rooms.get(conversation_id)
    await send(ws, {"type": "group-call-state", "conversationId": conversation_id, "participantIds": list(room.keys()) if room else []})


async def on_group_call_join(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    call_type = msg.get("callType")
    if not conversation_id or call_type not in ("audio", "video"):
        return

    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return await send(ws, {"type": "group-call-error", "conversationId": conversation_id, "error": "Not your conversation."})
    if ctx["kind"] != "group":
        return await send(ws, {"type": "group-call-error", "conversationId": conversation_id, "error": "Group calling is only available in groups."})

    # Guarded by a lock (unlike hub.js's reliance on Node's implicit
    # run-to-completion-between-awaits) because every send() here is itself
    # an `await` in Python and could otherwise let a second join interleave
    # mid-sequence — see the module docstring.
    async with _group_call_lock:
        room = group_call_rooms.get(conversation_id)
        existing = list(room.keys()) if room else []

        if user_id not in existing and len(existing) >= GROUP_CALL_CAP[call_type]:
            return await send(ws, {
                "type": "group-call-error", "conversationId": conversation_id,
                "error": f"This call is full (max {GROUP_CALL_CAP[call_type]} for {call_type}).",
            })

        if room is None:
            room = {}
            group_call_rooms[conversation_id] = room

        stale_ws = room.get(user_id)
        if stale_ws is not None and stale_ws is not ws:
            await send(stale_ws, {"type": "group-call-claimed", "conversationId": conversation_id})
            del room[user_id]
            for rid in ctx["memberIds"]:
                await fanout(rid, {"type": "group-call-participant-left", "conversationId": conversation_id, "userId": user_id}, ws)

        participant_ids = list(room.keys())  # snapshot BEFORE adding self
        room[user_id] = ws

        await send(ws, {"type": "group-call-state", "conversationId": conversation_id, "participantIds": participant_ids})
        for rid in ctx["memberIds"]:
            await fanout(rid, {"type": "group-call-participant-joined", "conversationId": conversation_id, "userId": user_id}, ws)


async def on_group_call_leave(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    if not conversation_id:
        return
    await remove_from_room(ws, user_id, conversation_id)


async def remove_from_room(ws: WebSocket, user_id: str, conversation_id: str):
    async with _group_call_lock:
        room = group_call_rooms.get(conversation_id)
        if not room or room.get(user_id) is not ws:
            return
        del room[user_id]
        if not room:
            del group_call_rooms[conversation_id]

    for rid in await member_ids(conversation_id):
        await fanout(rid, {"type": "group-call-participant-left", "conversationId": conversation_id, "userId": user_id})


async def leave_all_group_call_rooms(ws: WebSocket, user_id: str):
    for conversation_id in list(group_call_rooms.keys()):
        await remove_from_room(ws, user_id, conversation_id)


async def relay_group_call_frame(ws: WebSocket, user_id: str, msg: dict, frame_type: str):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    if not conversation_id or not to_user_id:
        return

    room = group_call_rooms.get(conversation_id)
    both_present = bool(room) and room.get(user_id) is ws and to_user_id in room
    if not both_present:
        return await send(ws, {"type": "group-call-error", "conversationId": conversation_id, "error": "Peer left the call.", "peerId": to_user_id})

    await fanout(to_user_id, {"type": frame_type, "conversationId": conversation_id, "fromUserId": user_id, "sdp": msg.get("sdp"), "candidate": msg.get("candidate")})


# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
async def member_ids(conversation_id: str) -> list[str]:
    rows = await query("SELECT user_id FROM conversation_members WHERE conversation_id = $1", conversation_id)
    return [r["user_id"] for r in rows]


async def conversation_context(conversation_id: str) -> dict | None:
    rows = await query(
        """SELECT cm.user_id, c.kind, c.status, c.requested_by
             FROM conversation_members cm
             JOIN conversations c ON c.id = cm.conversation_id
            WHERE cm.conversation_id = $1""",
        conversation_id,
    )
    if not rows:
        return None
    return {
        "memberIds": [r["user_id"] for r in rows],
        "kind": rows[0]["kind"],
        "status": rows[0]["status"],
        "requestedBy": rows[0]["requested_by"],
    }


def blocked_by_pending_request(ctx: dict, user_id: str) -> bool:
    return ctx["kind"] == "direct" and ctx["status"] == "pending" and user_id != ctx["requestedBy"]


async def deliver_scheduled_message(conversation_id: str, sender_id: str, ciphertext: str, iv: str) -> dict:
    """Delivers a message not triggered by a live 'send' frame — used by
    schedulers/scheduled_messages_scheduler.py once a scheduled message's
    time arrives. Same insert+receipts shape as on_send above."""
    ctx = await conversation_context(conversation_id)
    if not ctx or sender_id not in ctx["memberIds"]:
        raise ValueError("Sender is no longer a member of that conversation.")

    recipients = [i for i in ctx["memberIds"] if i != sender_id]

    async with transaction() as conn:
        row = await conn.fetchrow(
            """INSERT INTO messages (conversation_id, sender_id, kind, ciphertext, iv)
               VALUES ($1, $2, 'text', $3, $4)
               RETURNING id, sender_id, kind, ciphertext, iv, file_path, file_size, created_at, reply_to_id""",
            conversation_id, sender_id, ciphertext, iv,
        )
        row = dict(row)
        for rid in recipients:
            await conn.execute(
                "INSERT INTO message_receipts (message_id, user_id, delivered_at) VALUES ($1, $2, $3)",
                row["id"], rid, datetime.now(timezone.utc) if rid in sockets else None,
            )

    payload = shape_message(row)
    for rid in recipients:
        await fanout(rid, {"type": "message", "conversationId": conversation_id, "message": payload})
    await fanout(sender_id, {"type": "message", "conversationId": conversation_id, "message": payload})

    return payload
