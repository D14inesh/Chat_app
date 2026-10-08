"""WebSocket hub — mirrors src/ws/hub.js. Handles presence, typing, read
receipts, reactions, edit/delete, 1:1 WebRTC call signaling, group call
rooms, and live-game relay.

Several API workers run side by side (Nginx spreads users over them). Each
worker only holds its own sockets; delivering a frame, who's online,
ringing calls and group call seats are shared through Redis — see
app/core/bus.py. Without Redis it's all in this process, as before.

Connection liveness: the Node version manually pings every socket every 30s
and terminates non-answering ones (`ws.ping()`/`ws.on('pong')`). Here that's
delegated to uvicorn's underlying `websockets` implementation, which already
does transport-level ping/pong keepalive and drops dead connections on its
own (configured in main.py) — a WebSocketDisconnect on a dead socket reaches
the same on_close cleanup path either way. The separate JSON-level
`{"type": "ping"}` -> `{"type": "pong"}` handled in dispatch() below is a
distinct, additional app-level feature and is preserved as-is.
"""
import itertools
import json
import uuid
from datetime import datetime, timezone

from fastapi import HTTPException, WebSocket, WebSocketDisconnect

from app.core import bus
from app.core.security import COOKIE_NAME, set_cached_epoch, verify_session_live
from app.core.database import is_blocked_either_way, one, query, transaction
from app.utils import notify_push
from app.utils import signal_envelopes as sig
from app.utils.age import require_direct_allowed
from app.utils.serializers import shape_message

# userId -> set[WebSocket] open on THIS worker — a Set, not a single socket,
# so the same account open in several tabs/devices at once gets every event.
sockets: dict[str, set[WebSocket]] = {}

# The session epoch each socket signed in with — "log out other devices"
# closes every socket older than the new epoch (see close_sessions_older_than).
socket_epochs: dict[WebSocket, int] = {}

# Which phone/browser each socket is, and its Signal device number (if it
# has registered keys) — a Signal message is delivered to each socket as
# the one sealed copy made for that device.
socket_clients: dict[WebSocket, str | None] = {}
socket_signal_devices: dict[WebSocket, int | None] = {}


# Every socket's id, unique across workers ("<worker>:<n>"), so any worker
# can address one exact socket (a group call seat) through the bus.
socket_ids: dict[WebSocket, str] = {}
_by_sid: dict[str, WebSocket] = {}
_sid_counter = itertools.count(1)


async def set_signal_device(user_id: str, client: str, device: int | None):
    await bus.publish({"t": "sigdev", "u": str(user_id), "c": client, "d": device})


async def notify_contacts_devices_changed(user_id: str):
    """Someone added/replaced a device: everyone who chats with them (and
    their own other devices) refreshes the device list before sending."""
    rows = await query(
        """SELECT DISTINCT cm2.user_id FROM conversation_members cm1
             JOIN conversation_members cm2 ON cm2.conversation_id = cm1.conversation_id
            WHERE cm1.user_id = $1""",
        user_id,
    )
    frame = {"type": "signal-devices-changed", "userId": str(user_id)}
    for r in rows:
        await fanout(str(r["user_id"]), frame)
    await fanout(str(user_id), frame)

# Disappearing-message timers a chat can be set to (seconds): off, 24 hours,
# 7 days, 90 days — the same choices WhatsApp offers.
DISAPPEAR_CHOICES = {0, 86400, 604800, 7776000}
MAX_POLL_OPTIONS = 12

# A new message's expiry follows the chat's disappearing-messages timer at
# the moment it's sent ($1 is the conversation id in every insert using it).
_EXPIRES_SQL = """(SELECT CASE WHEN disappear_seconds > 0
                               THEN now() + make_interval(secs => disappear_seconds) END
                     FROM conversations WHERE id = $1)"""
_MESSAGE_COLUMNS = ("id, sender_id, kind, ciphertext, iv, file_path, file_size, created_at, reply_to_id, view_once, "
                    "expires_at, poll_closes_at, mention_all")

# Group call seats live in Redis: hash veyon:room:<conversationId> =
# {userId: socket id}. Changes to one room are serialised with a lock every
# worker respects (bus.lock), so "who's here / evict my stale tab / take my
# seat" stays atomic across workers. _my_rooms is just this worker's index of
# the rooms its sockets sit in (to leave them all on disconnect).
_my_rooms: dict[str, set[str]] = {}

GROUP_CALL_CAP = {"video": 4, "audio": 6}

# veyon:calls = {conversationId: call_logs.id} of the 1:1 call ringing/going
# on there, so a renegotiation offer mid-call isn't logged as a new call.
# veyon:gclog = {"<conversationId>|<userId>": call_logs.id} of a group seat.
CALLS = "veyon:calls"
GROUP_CALL_LOGS = "veyon:gclog"


def _room(conversation_id: str) -> str:
    return f"veyon:room:{conversation_id}"


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


def _dumps(obj: dict) -> str:
    return json.dumps(obj, default=_json_default)


async def _send_text(ws: WebSocket, text: str):
    try:
        await ws.send_text(text)
    except Exception:
        pass


async def fanout(user_id: str, obj: dict, except_ws: WebSocket | None = None):
    """Send to every socket a user has open — on any worker — optionally
    skipping one."""
    await bus.publish({"t": "user", "u": str(user_id), "m": _dumps(obj),
                       "x": socket_ids.get(except_ws) if except_ws is not None else None})


async def fanout_sealed(user_id: str, frame: dict, sealed: dict, except_ws: WebSocket | None = None,
                        field: str = "message"):
    """Like fanout(), for a Signal message: each socket gets the frame with
    its own device's sealed copy — in frame["message"]["envelope"], or in
    frame["envelope"] when field is "" (an edit)."""
    mine = {str(dev): env for (uid, dev), env in sealed.items() if str(uid) == str(user_id)}
    await bus.publish({"t": "sealed", "u": str(user_id), "m": _dumps(frame), "e": mine, "f": field,
                       "x": socket_ids.get(except_ws) if except_ws is not None else None})


async def _on_bus(ev: dict):
    """Runs on every worker for every published event."""
    t, user = ev.get("t"), ev.get("u")
    if t == "user":
        for ws in list(sockets.get(user, ())):
            if socket_ids.get(ws) != ev.get("x"):
                await _send_text(ws, ev["m"])
    elif t == "sealed":
        frame = json.loads(ev["m"])
        for ws in list(sockets.get(user, ())):
            if socket_ids.get(ws) == ev.get("x"):
                continue
            env = ev["e"].get(str(socket_signal_devices.get(ws)))
            if ev.get("f") == "message":
                out = {**frame, "message": {**frame["message"], "envelope": env}}
            else:
                out = {**frame, "envelope": env}
            await send(ws, out)
    elif t == "sock":
        ws = _by_sid.get(ev.get("s"))
        if ws is not None:
            await _send_text(ws, ev["m"])
    elif t == "close":
        for ws in list(sockets.get(user, ())):
            if socket_epochs.get(ws, 0) < ev["epoch"]:
                try:
                    await ws.close(code=4001, reason="Signed out from another device")
                except Exception:  # noqa: BLE001
                    pass
    elif t == "sigdev":
        for ws in sockets.get(user, ()):
            if socket_clients.get(ws) == ev.get("c"):
                socket_signal_devices[ws] = ev.get("d")
    elif t == "epoch":
        set_cached_epoch(user, int(ev["epoch"]))


bus.on_event(_on_bus)


async def is_online(user_id: str) -> bool:
    return await bus.is_online(str(user_id))


async def online_user_ids() -> list[str]:
    return await bus.online_user_ids()


async def notify_user(user_id: str, obj: dict):
    """Lets REST routes (accept/decline, etc.) push a live WS event without
    reaching into this module's socket registry directly."""
    await fanout(user_id, obj)


async def close_sessions_older_than(user_id: str, epoch: int):
    """Closes the user's sockets (on every worker) that signed in before
    `epoch` (code 4001 = signed out). The device that asked reconnects with
    its new token."""
    await bus.publish({"t": "close", "u": str(user_id), "epoch": epoch})


async def handle_connection(websocket: WebSocket):
    token = websocket.cookies.get(COOKIE_NAME)
    live = await verify_session_live(token)

    if not live:
        await websocket.close(code=4001, reason="Not signed in")
        return
    user_id, epoch = live

    await websocket.accept()
    socket_epochs[websocket] = epoch
    from app.api.v1.signal import my_signal_device
    from app.utils.devices import device_id as client_of
    socket_clients[websocket] = client_of(websocket)
    socket_signal_devices[websocket] = await my_signal_device(user_id, socket_clients[websocket])
    sid = f"{bus.WORKER}:{next(_sid_counter)}"
    socket_ids[websocket] = sid
    _by_sid[sid] = websocket
    sockets.setdefault(user_id, set()).add(websocket)

    # First socket for this user, on any worker = they just came online.
    if await bus.socket_opened(user_id):
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
        socket_epochs.pop(websocket, None)
        socket_clients.pop(websocket, None)
        socket_signal_devices.pop(websocket, None)
        await leave_all_group_call_rooms(websocket, user_id)
        _by_sid.pop(socket_ids.pop(websocket, None), None)

        conns = sockets.get(user_id)
        if conns is not None:
            conns.discard(websocket)
            if not conns:
                del sockets[user_id]
        # Their last socket on any worker = they just went offline.
        if await bus.socket_closed(user_id):
            await end_calls_of(user_id)
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
    if t == "poll-vote":
        return await on_poll_vote(ws, user_id, msg)
    if t == "close-poll":
        return await on_close_poll(ws, user_id, msg)
    if t == "pin-message":
        return await on_pin_message(ws, user_id, msg)
    if t == "set-disappearing":
        return await on_set_disappearing(ws, user_id, msg)
    if t == "view-once-opened":
        return await on_view_once_opened(ws, user_id, msg)
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
    # View-once only makes sense for a photo/video attachment.
    view_once = bool(msg.get("viewOnce")) and kind == "file"

    if not conversation_id or not ciphertext or not iv:
        return await send(ws, {"type": "error", "error": "Missing message fields", "tempId": temp_id})
    if kind not in ("text", "file", "voice", "location", "contact", "poll", "product"):
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
        if other_id:
            try:
                await require_direct_allowed(user_id, other_id)
            except HTTPException as e:
                return await send(ws, {"type": "error", "error": e.detail, "tempId": temp_id})
    if ctx["onlyAdminsSend"] and not is_group_admin(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Only admins can send messages in this group.", "tempId": temp_id})

    # Poll deadline (plain, so the server can stop late votes).
    poll_closes_at = None
    if kind == "poll" and msg.get("pollClosesAt"):
        try:
            poll_closes_at = datetime.fromisoformat(str(msg["pollClosesAt"]).replace("Z", "+00:00"))
        except ValueError:
            return await send(ws, {"type": "error", "error": "Bad poll deadline", "tempId": temp_id})
        if poll_closes_at.tzinfo is None:
            poll_closes_at = poll_closes_at.replace(tzinfo=timezone.utc)
        if poll_closes_at <= datetime.now(timezone.utc):
            return await send(ws, {"type": "error", "error": "Pick a closing time in the future.", "tempId": temp_id})
    # "@everyone" — groups only, owner/admins only.
    mention_all = bool(msg.get("mentionAll")) and is_group_admin(ctx, user_id)

    valid_reply_to_id = None
    if reply_to_id:
        target = await one(
            "SELECT 1 FROM messages WHERE id = $1 AND conversation_id = $2", reply_to_id, conversation_id
        )
        if target:
            valid_reply_to_id = reply_to_id

    recipients = [i for i in ctx["memberIds"] if i != user_id]
    online = await bus.online_among(recipients)

    # Signal: one sealed copy per device, checked against the current devices.
    envelopes = None
    if sig.is_signal(ciphertext):
        sender_device = socket_signal_devices.get(ws)
        envelopes = sig.parse(msg.get("envelopes"))
        if sender_device is None or envelopes is None:
            return await send(ws, {"type": "error", "error": "This device isn't set up for encryption yet — reload the page.", "tempId": temp_id})
        wrong = sig.mismatch(envelopes, await sig.expected_devices(ctx["memberIds"], user_id, sender_device))
        if wrong:
            return await send(ws, {"type": "signal-mismatch", "tempId": temp_id, "conversationId": conversation_id, "devices": wrong})
        iv = f"signal:{sender_device}"

    async with transaction() as conn:
        row = await conn.fetchrow(
            f"""INSERT INTO messages (conversation_id, sender_id, kind, ciphertext, iv, file_path, file_size,
                                      reply_to_id, view_once, poll_closes_at, mention_all, expires_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, {_EXPIRES_SQL})
               RETURNING {_MESSAGE_COLUMNS}""",
            conversation_id, user_id, kind, ciphertext, iv, file_path, file_size, valid_reply_to_id, view_once,
            poll_closes_at, mention_all,
        )
        row = dict(row)
        if envelopes is not None:
            await sig.store(conn, row["id"], envelopes)
        for rid in recipients:
            await conn.execute(
                "INSERT INTO message_receipts (message_id, user_id, delivered_at) VALUES ($1, $2, $3)",
                row["id"], rid, datetime.now(timezone.utc) if str(rid) in online else None,
            )

    payload = shape_message(row)

    await send(ws, {"type": "sent", "tempId": temp_id, "message": payload, "conversationId": conversation_id})
    frame = {"type": "message", "conversationId": conversation_id, "message": payload}
    if envelopes is not None:
        sealed = sig.by_device(envelopes)
        for rid in recipients:
            await fanout_sealed(rid, frame, sealed)
        await fanout_sealed(user_id, frame, sealed, ws)
    else:
        for rid in recipients:
            await fanout(rid, frame)
        await fanout(user_id, frame, ws)
    # People with no tab or app open get a push notification instead.
    notify_push.fire(notify_push.message(
        conversation_id, user_id, kind, mention_all, [r for r in recipients if str(r) not in online]))

    # A business that's "away" answers a customer automatically.
    if ctx["kind"] == "direct" and recipients:
        from app.api.v1.business_tools import maybe_auto_reply
        try:
            await maybe_auto_reply(conversation_id, user_id, recipients[0])
        except Exception as err:  # noqa: BLE001 — never break sending over this
            print(f"[auto-reply] {err!r}")


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

    # Read receipts off (either person, 1-to-1 chats): no blue ticks sent.
    from app.utils.privacy import reads_hidden
    if await reads_hidden(conversation_id):
        return

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

    row = await one(
        "SELECT sender_id, kind, ciphertext, iv, coalesce(edited_at, created_at) AS written_at FROM messages WHERE id = $1 AND conversation_id = $2",
        message_id, conversation_id,
    )
    if not row or row["sender_id"] != user_id:
        return await send(ws, {"type": "error", "error": "You can only edit your own messages."})
    if row["kind"] != "text":
        return await send(ws, {"type": "error", "error": "Only text messages can be edited."})
    envelopes = None
    if sig.is_signal(ciphertext):
        sender_device = socket_signal_devices.get(ws)
        envelopes = sig.parse(msg.get("envelopes"))
        if sender_device is None or envelopes is None:
            return await send(ws, {"type": "error", "error": "This device isn't set up for encryption yet — reload the page."})
        ctx = await conversation_context(conversation_id)
        wrong = sig.mismatch(envelopes, await sig.expected_devices(ctx["memberIds"], user_id, sender_device))
        if wrong:
            return await send(ws, {"type": "signal-mismatch", "editOf": message_id, "conversationId": conversation_id, "devices": wrong})
        iv = f"signal:{sender_device}"
    # Keep the version being replaced, for "Edit history".
    await query(
        "INSERT INTO message_edits (message_id, ciphertext, iv, written_at) VALUES ($1, $2, $3, $4)",
        message_id, row["ciphertext"], row["iv"], row["written_at"],
    )

    updated = await one(
        "UPDATE messages SET ciphertext = $1, iv = $2, edited_at = now() WHERE id = $3 RETURNING edited_at",
        ciphertext, iv, message_id,
    )
    if envelopes is not None:
        async with transaction() as conn:
            await sig.store(conn, message_id, envelopes)

    edited = {"type": "message-edited", "conversationId": conversation_id, "messageId": message_id,
              "ciphertext": ciphertext, "iv": iv, "editedAt": updated["edited_at"]}
    for rid in await member_ids(conversation_id):
        if envelopes is None:
            await fanout(rid, edited)
            continue
        await fanout_sealed(rid, edited, sig.by_device(envelopes), field="")


async def _message_in(conversation_id: str, message_id: str) -> dict | None:
    """A live (not deleted, not expired) message of this conversation."""
    return await one(
        f"""SELECT {_MESSAGE_COLUMNS}, edited_at FROM messages
             WHERE id = $1 AND conversation_id = $2 AND deleted_at IS NULL
               AND (expires_at IS NULL OR expires_at > now())""",
        message_id, conversation_id,
    )


async def poll_votes(message_id: str) -> list[dict]:
    rows = await query("SELECT user_id, choices FROM poll_votes WHERE message_id = $1 ORDER BY voted_at", message_id)
    return [{"userId": r["user_id"], "choices": list(r["choices"])} for r in rows]


async def on_poll_vote(ws: WebSocket, user_id: str, msg: dict):
    """Vote (or change/retract a vote — empty choices) on a poll. The server
    only ever sees option numbers; the question and options stay encrypted."""
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    choices = msg.get("choices")
    if not conversation_id or not message_id or not isinstance(choices, list):
        return
    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Accept the request before you can vote."})
    target = await _message_in(conversation_id, message_id)
    if not target or target["kind"] != "poll":
        return
    if target["poll_closes_at"] and target["poll_closes_at"] <= datetime.now(timezone.utc):
        return await send(ws, {"type": "error", "error": "This poll has closed."})
    try:
        picked = sorted({int(c) for c in choices})
    except (TypeError, ValueError):
        return
    if any(c < 0 or c >= MAX_POLL_OPTIONS for c in picked):
        return

    if picked:
        await query(
            """INSERT INTO poll_votes (message_id, user_id, choices) VALUES ($1, $2, $3)
               ON CONFLICT (message_id, user_id) DO UPDATE SET choices = EXCLUDED.choices, voted_at = now()""",
            message_id, user_id, picked,
        )
    else:
        await query("DELETE FROM poll_votes WHERE message_id = $1 AND user_id = $2", message_id, user_id)

    votes = await poll_votes(message_id)
    for rid in ctx["memberIds"]:
        await fanout(rid, {"type": "poll-votes", "conversationId": conversation_id, "messageId": message_id, "votes": votes})


async def on_close_poll(ws: WebSocket, user_id: str, msg: dict):
    """The poll's creator (or a group admin) closes it now."""
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    ctx = await conversation_context(conversation_id) if conversation_id else None
    if not ctx or user_id not in ctx["memberIds"]:
        return
    target = await _message_in(conversation_id, message_id)
    if not target or target["kind"] != "poll":
        return
    if target["sender_id"] != user_id and not is_group_admin(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Only the person who made the poll can close it."})
    row = await one(
        """UPDATE messages SET poll_closes_at = LEAST(coalesce(poll_closes_at, now()), now())
            WHERE id = $1 RETURNING poll_closes_at""",
        message_id,
    )
    for rid in ctx["memberIds"]:
        await fanout(rid, {"type": "poll-closed", "conversationId": conversation_id, "messageId": message_id,
                           "closesAt": row["poll_closes_at"]})


async def on_pin_message(ws: WebSocket, user_id: str, msg: dict):
    """Pin a message to the top of the chat for everyone (messageId null =
    unpin). One pinned message per chat; pinning another replaces it."""
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    if not conversation_id:
        return
    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Accept the request before you can pin messages."})

    pinned = None
    if message_id:
        target = await _message_in(conversation_id, message_id)
        if not target:
            return await send(ws, {"type": "error", "error": "That message can't be pinned."})
        pinned = shape_message(target)
    await query(
        "UPDATE conversations SET pinned_message_id = $2, pinned_by = $3 WHERE id = $1",
        conversation_id, message_id or None, user_id if message_id else None,
    )
    for rid in ctx["memberIds"]:
        await fanout(rid, {
            "type": "message-pinned", "conversationId": conversation_id,
            "message": pinned, "pinnedBy": user_id if pinned else None,
        })


async def on_set_disappearing(ws: WebSocket, user_id: str, msg: dict):
    """Turn disappearing messages on/off for everyone in the chat. Applies to
    messages sent from now on (like WhatsApp), not to older ones."""
    conversation_id = msg.get("conversationId")
    try:
        seconds = int(msg.get("seconds") or 0)
    except (TypeError, ValueError):
        return
    if not conversation_id or seconds not in DISAPPEAR_CHOICES:
        return
    ctx = await conversation_context(conversation_id)
    if not ctx or user_id not in ctx["memberIds"]:
        return
    if blocked_by_pending_request(ctx, user_id):
        return await send(ws, {"type": "error", "error": "Accept the request first."})

    await query("UPDATE conversations SET disappear_seconds = $2 WHERE id = $1", conversation_id, seconds)
    for rid in ctx["memberIds"]:
        await fanout(rid, {
            "type": "disappearing-changed", "conversationId": conversation_id,
            "seconds": seconds, "byUserId": user_id,
        })


async def on_view_once_opened(ws: WebSocket, user_id: str, msg: dict):
    """A recipient opened a view-once photo/video: remembered so the file is
    never handed to them again, and the sender sees "Opened"."""
    conversation_id = msg.get("conversationId")
    message_id = msg.get("messageId")
    if not conversation_id or not message_id:
        return
    members = await member_ids(conversation_id)
    if user_id not in members:
        return
    target = await _message_in(conversation_id, message_id)
    if not target or not target["view_once"] or target["sender_id"] == user_id:
        return
    await query(
        "INSERT INTO message_opens (message_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        message_id, user_id,
    )
    for rid in members:
        await fanout(rid, {"type": "view-once-opened", "conversationId": conversation_id, "messageId": message_id, "userId": user_id})


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
            WHERE mine.user_id = $1
              -- Only people allowed to see my last seen / online (Privacy).
              AND veyon_can_see($1, other.user_id, (SELECT last_seen_privacy FROM users WHERE id = $1))""",
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
    try:
        await require_direct_allowed(user_id, to_user_id)
    except HTTPException as e:
        return await send(ws, {"type": "call-error", "conversationId": conversation_id, "error": e.detail})

    await log_call_offer(conversation_id, user_id, to_user_id, call_type)
    if not await is_online(to_user_id):   # nothing open to ring on: push a notification
        notify_push.fire(notify_push.call(conversation_id, user_id, to_user_id, call_type))
    await fanout(to_user_id, {"type": "call-offer", "conversationId": conversation_id, "fromUserId": user_id, "callType": call_type, "sdp": sdp})
    await fanout(user_id, {"type": "call-started-elsewhere", "conversationId": conversation_id, "toUserId": to_user_id, "callType": call_type}, ws)


async def on_call_answer(ws: WebSocket, user_id: str, msg: dict):
    to_user_id = msg.get("toUserId")
    conversation_id = msg.get("conversationId")
    sdp = msg.get("sdp")
    if not conversation_id or not to_user_id or not sdp:
        return
    await log_call_status(conversation_id, "answered")
    await fanout(to_user_id, {"type": "call-answer", "conversationId": conversation_id, "fromUserId": user_id, "sdp": sdp})
    await fanout(user_id, {"type": "call-claimed", "conversationId": conversation_id}, ws)


async def on_call_decline(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    if not conversation_id or not to_user_id:
        return
    # The caller hanging up while it rings also arrives as a decline — for
    # the person being called that's a missed call, not a declined one.
    log_id = await bus.hget(CALLS, conversation_id)
    caller = await one("SELECT caller_id FROM call_logs WHERE id = $1", int(log_id)) if log_id else None
    await log_call_status(conversation_id, "ended" if caller and str(caller["caller_id"]) == str(user_id) else "declined")
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
    await log_call_status(conversation_id, "ended")
    await fanout(to_user_id, {"type": "call-end", "conversationId": conversation_id, "fromUserId": user_id})


# ── Call history ─────────────────────────────────────────────

async def log_call_offer(conversation_id: str, caller: str, callee: str, call_type: str):
    log_id = await bus.hget(CALLS, conversation_id)
    if log_id:
        row = await one("SELECT status, started_at FROM call_logs WHERE id = $1", int(log_id))
        fresh = row and (row["status"] == "answered" or (datetime.now(timezone.utc) - row["started_at"]).total_seconds() < 90)
        if fresh:
            return  # renegotiation of the same call
        await log_call_status(conversation_id, "ended")
    row = await one(
        "INSERT INTO call_logs (conversation_id, caller_id, callee_id, call_type) VALUES ($1, $2, $3, $4) RETURNING id",
        conversation_id, caller, callee, call_type,
    )
    await bus.hset(CALLS, conversation_id, str(row["id"]))


async def log_call_status(conversation_id: str, event: str):
    """event: answered | declined | ended. Ending an unanswered call = missed."""
    log_id = await bus.hget(CALLS, conversation_id)
    if not log_id:
        return
    log_id = int(log_id)
    if event == "answered":
        await query("UPDATE call_logs SET status = 'answered', answered_at = coalesce(answered_at, now()) WHERE id = $1", log_id)
        return
    await bus.hdel(CALLS, conversation_id)
    row = await one(
        """UPDATE call_logs SET ended_at = now(),
                  status = CASE WHEN $2 = 'declined' THEN 'declined'
                                WHEN status = 'answered' THEN 'answered' ELSE 'missed' END
            WHERE id = $1 RETURNING status, callee_id, caller_id""",
        log_id, event,
    )
    if row:
        for uid in (row["caller_id"], row["callee_id"]):
            if uid:
                await fanout(uid, {"type": "call-log", "status": row["status"], "conversationId": conversation_id})


async def end_calls_of(user_id: str):
    """Their last connection dropped: close any 1:1 call they were in."""
    for conversation_id, log_id in (await bus.hgetall(CALLS)).items():
        row = await one("SELECT 1 FROM call_logs WHERE id = $1 AND (caller_id = $2 OR callee_id = $2)", int(log_id), user_id)
        if row:
            await log_call_status(conversation_id, "ended")


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
    room = await bus.hgetall(_room(conversation_id))
    await send(ws, {"type": "group-call-state", "conversationId": conversation_id, "participantIds": list(room)})


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

    # Guarded by a lock every worker respects: every await here could
    # otherwise let a second join (on this or another worker) interleave.
    my_sid = socket_ids.get(ws)
    async with bus.lock(f"room:{conversation_id}"):
        room = await bus.hgetall(_room(conversation_id))
        existing = list(room)

        if user_id not in existing and len(existing) >= GROUP_CALL_CAP[call_type]:
            return await send(ws, {
                "type": "group-call-error", "conversationId": conversation_id,
                "error": f"This call is full (max {GROUP_CALL_CAP[call_type]} for {call_type}).",
            })

        stale_sid = room.get(user_id)
        if stale_sid is not None and stale_sid != my_sid:
            # My other tab/phone had the seat: tell it, and take the seat.
            await bus.publish({"t": "sock", "s": stale_sid,
                               "m": _dumps({"type": "group-call-claimed", "conversationId": conversation_id})})
            del room[user_id]
            for rid in ctx["memberIds"]:
                await fanout(rid, {"type": "group-call-participant-left", "conversationId": conversation_id, "userId": user_id}, ws)

        participant_ids = [u for u in room if u != user_id]  # snapshot BEFORE adding self
        await bus.hset(_room(conversation_id), user_id, my_sid)
        _my_rooms.setdefault(my_sid, set()).add(conversation_id)

        await send(ws, {"type": "group-call-state", "conversationId": conversation_id, "participantIds": participant_ids})
        seat = f"{conversation_id}|{user_id}"
        if not await bus.hget(GROUP_CALL_LOGS, seat):
            row = await one(
                """INSERT INTO call_logs (conversation_id, caller_id, is_group, call_type, status, answered_at)
                   VALUES ($1, $2, true, $3, 'answered', now()) RETURNING id""",
                conversation_id, user_id, msg.get("callType") if msg.get("callType") in ("audio", "video") else "audio",
            )
            await bus.hset(GROUP_CALL_LOGS, seat, str(row["id"]))
        for rid in ctx["memberIds"]:
            await fanout(rid, {"type": "group-call-participant-joined", "conversationId": conversation_id, "userId": user_id}, ws)


async def on_group_call_leave(ws: WebSocket, user_id: str, msg: dict):
    conversation_id = msg.get("conversationId")
    if not conversation_id:
        return
    await remove_from_room(ws, user_id, conversation_id)


async def remove_from_room(ws: WebSocket, user_id: str, conversation_id: str):
    my_sid = socket_ids.get(ws)
    async with bus.lock(f"room:{conversation_id}"):
        if my_sid is None or await bus.hget(_room(conversation_id), user_id) != my_sid:
            return
        await bus.hdel(_room(conversation_id), user_id)
    _my_rooms.get(my_sid, set()).discard(conversation_id)
    seat = f"{conversation_id}|{user_id}"
    log_id = await bus.hget(GROUP_CALL_LOGS, seat)
    if log_id:
        await bus.hdel(GROUP_CALL_LOGS, seat)
        await query("UPDATE call_logs SET ended_at = now() WHERE id = $1", int(log_id))

    for rid in await member_ids(conversation_id):
        await fanout(rid, {"type": "group-call-participant-left", "conversationId": conversation_id, "userId": user_id})


async def leave_all_group_call_rooms(ws: WebSocket, user_id: str):
    my_sid = socket_ids.get(ws)
    for conversation_id in list(_my_rooms.get(my_sid, ())):
        await remove_from_room(ws, user_id, conversation_id)
    _my_rooms.pop(my_sid, None)


async def relay_group_call_frame(ws: WebSocket, user_id: str, msg: dict, frame_type: str):
    conversation_id = msg.get("conversationId")
    to_user_id = msg.get("toUserId")
    if not conversation_id or not to_user_id:
        return

    room = await bus.hgetall(_room(conversation_id))
    both_present = bool(room) and room.get(user_id) == socket_ids.get(ws) and to_user_id in room
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
        """SELECT cm.user_id, cm.role, c.kind, c.status, c.requested_by, c.only_admins_send
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
        "roles": {r["user_id"]: r["role"] for r in rows},
        "onlyAdminsSend": bool(rows[0]["only_admins_send"]),
    }


def is_group_admin(ctx: dict, user_id: str) -> bool:
    return ctx["kind"] == "group" and ctx["roles"].get(user_id) in ("owner", "admin")


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
    online = await bus.online_among(recipients)

    async with transaction() as conn:
        row = await conn.fetchrow(
            f"""INSERT INTO messages (conversation_id, sender_id, kind, ciphertext, iv, expires_at)
               VALUES ($1, $2, 'text', $3, $4, {_EXPIRES_SQL})
               RETURNING {_MESSAGE_COLUMNS}""",
            conversation_id, sender_id, ciphertext, iv,
        )
        row = dict(row)
        for rid in recipients:
            await conn.execute(
                "INSERT INTO message_receipts (message_id, user_id, delivered_at) VALUES ($1, $2, $3)",
                row["id"], rid, datetime.now(timezone.utc) if str(rid) in online else None,
            )

    payload = shape_message(row)
    for rid in recipients:
        await fanout(rid, {"type": "message", "conversationId": conversation_id, "message": payload})
    await fanout(sender_id, {"type": "message", "conversationId": conversation_id, "message": payload})

    return payload
