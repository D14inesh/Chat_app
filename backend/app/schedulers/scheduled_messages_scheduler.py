"""Mirrors src/scheduled-messages-scheduler.js. Shorter poll than the
reminders scheduler (15s vs 30s) — messages feel more time-sensitive."""
import asyncio

from app.core.database import query
from app.websocket.manager import deliver_scheduled_message

POLL_INTERVAL_S = 15


async def _tick():
    due = await query(
        """SELECT id, conversation_id, sender_id, ciphertext, iv
             FROM scheduled_messages
            WHERE sent_at IS NULL AND send_at <= now()
            ORDER BY send_at ASC
            LIMIT 50"""
    )
    for row in due:
        try:
            await deliver_scheduled_message(row["conversation_id"], row["sender_id"], row["ciphertext"], row["iv"])
        except Exception as err:  # noqa: BLE001
            print(f"[scheduled-messages] delivery failed for {row['id']}: {err!r}")
        # Marked done either way — including on failure (e.g. the sender left
        # the conversation before it fired). No retry queue, same as the
        # reminders scheduler — a permanently-broken row would otherwise loop forever.
        await query("UPDATE scheduled_messages SET sent_at = now() WHERE id = $1", row["id"])


async def run_scheduled_messages_poller():
    while True:
        await _tick()
        await asyncio.sleep(POLL_INTERVAL_S)
