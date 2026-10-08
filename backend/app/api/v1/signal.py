"""Signal protocol key directory (X3DH).

Every phone and browser is its own Signal device with its own keys, which
never leave it: an identity key, a signed pre-key and a batch of one-time
pre-keys. The server only stores the PUBLIC halves and hands out one
"bundle" per device so others can start an encrypted session with it.
Messages then carry one sealed copy per device (message_envelopes); the
server can't read any of them.

Device numbers are per account (1, 2, 3 …) and assigned here. A device is
recognised by the same id the rest of the app uses (utils/devices.py: the
phone's own id, or the browser's long-lived cookie)."""
from fastapi import APIRouter, Depends, HTTPException, Request, Response

from app.core.database import one, query, transaction
from app.core.security import require_auth
from app.utils.devices import device_id

router = APIRouter(prefix="/api/signal")

MAX_DEVICES = 10           # per account
MAX_PREKEYS_PER_UPLOAD = 200
_KEY_LEN = 200             # base64 of a 33-byte key / 64-byte signature fits easily


def _key(v, field: str) -> str:
    s = str(v or "").strip()
    if not s or len(s) > _KEY_LEN:
        raise HTTPException(400, f"Bad {field}.")
    return s


def _prekeys(raw) -> list[tuple[int, str]]:
    keys = raw or []
    if not isinstance(keys, list) or len(keys) > MAX_PREKEYS_PER_UPLOAD:
        raise HTTPException(400, "Bad pre-keys.")
    return [(int(k["keyId"]), _key(k.get("publicKey"), "pre-key")) for k in keys]


async def my_signal_device(user_id: str, client: str | None) -> int | None:
    """This phone/browser's Signal device number for the account, if registered."""
    if not client:
        return None
    row = await one("SELECT device_id FROM signal_devices WHERE user_id = $1 AND client_id = $2", user_id, client)
    return row["device_id"] if row else None


@router.post("/devices")
async def register_device(request: Request, response: Response, uid: str = Depends(require_auth)):
    """(Re)registers THIS device's public keys. A device that lost its keys
    (browser data cleared, app reinstalled) registers again and gets a new
    number, so other people's old sessions with it are never reused."""
    body = await request.json()
    client = device_id(request, response)
    if not client:
        raise HTTPException(400, "This device can't be identified.")
    reg_id = int(body.get("registrationId") or 0)
    identity = _key(body.get("identityKey"), "identity key")
    spk = body.get("signedPreKey") or {}
    spk_id = int(spk.get("keyId") or 0)
    spk_pub = _key(spk.get("publicKey"), "signed pre-key")
    spk_sig = _key(spk.get("signature"), "signature")
    pre = _prekeys(body.get("preKeys"))
    if not (0 < reg_id < 2 ** 31):
        raise HTTPException(400, "Bad registration id.")

    async with transaction() as conn:
        await conn.execute("DELETE FROM signal_devices WHERE user_id = $1 AND client_id = $2", uid, client)
        count = await conn.fetchval("SELECT count(*) FROM signal_devices WHERE user_id = $1", uid)
        if count >= MAX_DEVICES:
            # Make room: drop the device unused for longest.
            await conn.execute(
                """DELETE FROM signal_devices WHERE (user_id, device_id) IN (
                     SELECT user_id, device_id FROM signal_devices WHERE user_id = $1 ORDER BY last_seen LIMIT 1)""",
                uid,
            )
        next_id = await conn.fetchval("SELECT coalesce(max(device_id), 0) + 1 FROM signal_device_counters WHERE user_id = $1", uid)
        await conn.execute(
            """INSERT INTO signal_device_counters (user_id, device_id) VALUES ($1, $2)""", uid, next_id,
        )
        await conn.execute(
            """INSERT INTO signal_devices (user_id, device_id, client_id, registration_id, identity_key,
                                           signed_prekey_id, signed_prekey, signed_prekey_sig)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
            uid, next_id, client, reg_id, identity, spk_id, spk_pub, spk_sig,
        )
        if pre:
            await conn.executemany(
                "INSERT INTO signal_prekeys (user_id, device_id, key_id, public_key) VALUES ($1, $2, $3, $4) "
                "ON CONFLICT DO NOTHING",
                [(uid, next_id, k, p) for k, p in pre],
            )

    from app.websocket import manager as hub
    await hub.set_signal_device(uid, client, next_id)
    # People who chat with this account should start fresh sessions.
    await hub.notify_contacts_devices_changed(uid)
    return {"deviceId": next_id}


@router.get("/me")
async def my_device(request: Request, uid: str = Depends(require_auth)):
    """Is this device registered, and how many one-time pre-keys are left?"""
    dev = await my_signal_device(uid, device_id(request))
    if dev is None:
        return {"deviceId": None, "preKeys": 0}
    n = await one("SELECT count(*) AS n FROM signal_prekeys WHERE user_id = $1 AND device_id = $2", uid, dev)
    await query("UPDATE signal_devices SET last_seen = now() WHERE user_id = $1 AND device_id = $2", uid, dev)
    return {"deviceId": dev, "preKeys": n["n"]}


@router.post("/prekeys")
async def top_up_prekeys(request: Request, uid: str = Depends(require_auth)):
    """More one-time pre-keys for this device (each is used up once)."""
    dev = await my_signal_device(uid, device_id(request))
    if dev is None:
        raise HTTPException(409, "This device isn't registered for encryption yet.")
    pre = _prekeys((await request.json()).get("preKeys"))
    if pre:
        from app.core.database import pool
        async with pool.acquire() as conn:
            await conn.executemany(
                "INSERT INTO signal_prekeys (user_id, device_id, key_id, public_key) VALUES ($1, $2, $3, $4) "
                "ON CONFLICT DO NOTHING",
                [(uid, dev, k, p) for k, p in pre],
            )
    return {"ok": True, "added": len(pre)}


@router.get("/devices/{user_id}")
async def list_devices(user_id: str, uid: str = Depends(require_auth)):
    rows = await query("SELECT device_id FROM signal_devices WHERE user_id = $1 ORDER BY device_id", user_id)
    return {"devices": [r["device_id"] for r in rows]}


@router.get("/bundles/{user_id}")
async def bundles(user_id: str, uid: str = Depends(require_auth)):
    """One pre-key bundle per device of `user_id` (uses up one one-time
    pre-key each). Optional ?device=N narrows it to one device."""
    rows = await query(
        """SELECT device_id, registration_id, identity_key, signed_prekey_id, signed_prekey, signed_prekey_sig
             FROM signal_devices WHERE user_id = $1 ORDER BY device_id""",
        user_id,
    )
    out = []
    for r in rows:
        pk = await one(
            """DELETE FROM signal_prekeys WHERE (user_id, device_id, key_id) IN (
                 SELECT user_id, device_id, key_id FROM signal_prekeys
                  WHERE user_id = $1 AND device_id = $2 ORDER BY key_id LIMIT 1)
               RETURNING key_id, public_key""",
            user_id, r["device_id"],
        )
        out.append({
            "deviceId": r["device_id"],
            "registrationId": r["registration_id"],
            "identityKey": r["identity_key"],
            "signedPreKey": {"keyId": r["signed_prekey_id"], "publicKey": r["signed_prekey"],
                             "signature": r["signed_prekey_sig"]},
            "preKey": {"keyId": pk["key_id"], "publicKey": pk["public_key"]} if pk else None,
        })
    return {"userId": user_id, "devices": out}


async def forget_device(user_id: str, client: str | None):
    """Signing out of a device removes its Signal keys from the directory
    (the device deletes its own copy too)."""
    if client:
        await query("DELETE FROM signal_devices WHERE user_id = $1 AND client_id = $2", user_id, client)
