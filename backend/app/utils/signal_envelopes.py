"""Signal messages on the wire: one sealed copy ("envelope") per receiving
device. The message row itself only says `ciphertext = 'signal'` and
`iv = 'signal:<sending device>'`; the envelopes carry the encrypted text.

The sender must seal a copy for every current Signal device of everyone in
the chat (and for their own other devices, so those show the sent message
too). If the device list changed under them, the send is refused with the
up-to-date list so the sender can seal for the right devices and retry —
the same "mismatched devices" step the Signal servers do."""
from app.core.database import query

SIGNAL = "signal"
KINDS = {1, 3}            # 1 = normal message, 3 = first message of a session (pre-key)
MAX_BODY = 200_000         # base64 of a sealed text message, generous


def is_signal(ciphertext: str | None) -> bool:
    return ciphertext == SIGNAL


def sender_device_of(iv: str | None) -> int | None:
    if iv and iv.startswith("signal:"):
        try:
            return int(iv.split(":", 1)[1])
        except ValueError:
            return None
    return None


def parse(raw) -> list[tuple[str, int, int, str]] | None:
    """[(user_id, device_id, kind, body)] or None if malformed."""
    if not isinstance(raw, list) or not raw or len(raw) > 500:
        return None
    out = []
    for e in raw:
        try:
            uid, dev, kind, body = str(e["userId"]), int(e["deviceId"]), int(e["type"]), str(e["body"])
        except (KeyError, TypeError, ValueError):
            return None
        if kind not in KINDS or not body or len(body) > MAX_BODY:
            return None
        out.append((uid, dev, kind, body))
    return out


async def expected_devices(member_ids: list[str], sender_id: str, sender_device: int) -> dict[str, set[int]]:
    rows = await query(
        "SELECT user_id, device_id FROM signal_devices WHERE user_id = ANY($1::uuid[])", list(member_ids),
    )
    out: dict[str, set[int]] = {str(m): set() for m in member_ids}
    for r in rows:
        uid, dev = str(r["user_id"]), r["device_id"]
        if uid == str(sender_id) and dev == sender_device:
            continue
        out[uid].add(dev)
    return out


def mismatch(envelopes, expected: dict[str, set[int]]) -> dict | None:
    """None when the envelopes cover exactly the current devices; otherwise
    {userId: [current device ids]} for every user whose list differs."""
    given: dict[str, set[int]] = {}
    for uid, dev, _, _ in envelopes:
        given.setdefault(uid, set()).add(dev)
    wrong = {uid: sorted(devs) for uid, devs in expected.items() if given.get(uid, set()) != devs}
    wrong.update({uid: [] for uid in given if uid not in expected})
    return wrong or None


async def store(conn, message_id, envelopes):
    await conn.execute("DELETE FROM message_envelopes WHERE message_id = $1", message_id)
    await conn.executemany(
        "INSERT INTO message_envelopes (message_id, user_id, device_id, kind, body) VALUES ($1, $2, $3, $4, $5)",
        [(message_id, uid, dev, kind, body) for uid, dev, kind, body in envelopes],
    )


async def for_device(message_ids: list, user_id: str, device: int | None) -> dict:
    """{message_id: {type, body}} — this device's sealed copies."""
    if device is None or not message_ids:
        return {}
    rows = await query(
        """SELECT message_id, kind, body FROM message_envelopes
            WHERE message_id = ANY($1::uuid[]) AND user_id = $2 AND device_id = $3""",
        list(message_ids), user_id, device,
    )
    return {r["message_id"]: {"type": r["kind"], "body": r["body"]} for r in rows}


def by_device(envelopes) -> dict[tuple[str, int], dict]:
    return {(uid, dev): {"type": kind, "body": body} for uid, dev, kind, body in envelopes}
