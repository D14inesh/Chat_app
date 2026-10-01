"""Mirrors src/reminders-scheduler.js. pywebpush's webpush() is a blocking
call (it uses `requests` under the hood) — run via asyncio.to_thread so it
doesn't stall the event loop's WebSocket/HTTP handling while waiting on a
push service round trip."""
import asyncio
import json
import random

from pywebpush import WebPushException, webpush

from app.core.config import VAPID_PRIVATE_KEY, VAPID_PUBLIC_KEY, VAPID_SUBJECT
from app.core.database import query

POLL_INTERVAL_S = 30

# A few options per category, picked at random each time so a recurring
# reminder doesn't read the exact same notification twice in a row. The
# user's own note becomes the notification body — these are just the title.
CATEGORY_TITLES = {
    "birthday": ["🎂 Happy Birthday!", "🎉 It's your special day!", "🎈 Wishing you the happiest birthday!"],
    "happy": ["😊 Something to smile about", "🌟 A happy little reminder", "🥳 Celebrating this with you"],
    "love": ["❤️ A love note for you", "💕 Thinking of you", "💖 Sending you love"],
    "sad": ["🤗 Sending you strength", "💙 You're not alone in this", "🫂 Thinking of you today"],
    "breakup": ["💙 Be gentle with yourself", "🌤️ This too shall pass", "🫶 You deserve peace"],
    "general": ["⏰ Reminder"],
}


def pick_title(category: str) -> str:
    options = CATEGORY_TITLES.get(category, CATEGORY_TITLES["general"])
    return random.choice(options)


def _send_one(endpoint: str, p256dh: str, auth: str, payload: str):
    webpush(
        subscription_info={"endpoint": endpoint, "keys": {"p256dh": p256dh, "auth": auth}},
        data=payload,
        vapid_private_key=VAPID_PRIVATE_KEY,
        vapid_claims={"sub": VAPID_SUBJECT},
    )


async def deliver_reminder(reminder: dict):
    subs = await query(
        "SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = $1",
        reminder["user_id"],
    )

    payload = json.dumps({
        "title": pick_title(reminder["category"]),
        "body": reminder["content"],
        "reminderId": reminder["id"],
        "category": reminder["category"],
    })

    async def send(sub: dict):
        try:
            await asyncio.to_thread(_send_one, sub["endpoint"], sub["p256dh"], sub["auth"], payload)
        except WebPushException as err:
            status_code = err.response.status_code if err.response is not None else None
            # 404/410 means the browser/OS permanently invalidated this
            # subscription — anything else is transient, leave it for next tick.
            if status_code in (404, 410):
                await query("DELETE FROM push_subscriptions WHERE id = $1", sub["id"])
            else:
                print(f"[reminders] push failed: {sub['endpoint']} {err}")

    await asyncio.gather(*(send(s) for s in subs))

    # Marked done once delivery to every currently-subscribed device has been
    # attempted — including "zero subscriptions found" — no per-device retry
    # queue; a transient failure above is logged, not retried.
    await query("UPDATE reminders SET notified_at = now() WHERE id = $1", reminder["id"])


async def _tick():
    due = await query(
        """SELECT id, user_id, content, category
             FROM reminders
            WHERE notified_at IS NULL AND remind_at <= now()
            ORDER BY remind_at ASC
            LIMIT 50"""
    )
    for reminder in due:
        try:
            await deliver_reminder(reminder)
        except Exception as err:  # noqa: BLE001
            print(f"[reminders] delivery failed for {reminder['id']}: {err!r}")


async def run_reminder_scheduler():
    """Starts the background poll loop. A no-op (with a warning) if VAPID
    keys aren't configured — see .env.example."""
    if not VAPID_PUBLIC_KEY or not VAPID_PRIVATE_KEY:
        print("  Reminders: VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY not set — push notifications are disabled.")
        return
    while True:
        await _tick()
        await asyncio.sleep(POLL_INTERVAL_S)
