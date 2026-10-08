"""Sign-in approval: a sign-in from a device or browser the account hasn't
used before waits until the owner accepts it — from the email sent to the
account's Gmail, or from a device they're already signed in on.

Devices an account has already used are "trusted" (trusted_devices) and
sign in straight away; so does the very first device of an account, and
accounts without a verified Gmail (there'd be nowhere to ask)."""
import asyncio
import hashlib
import html
import secrets
import smtplib
from email.message import EmailMessage

from fastapi import Request

from app.core import config
from app.core.database import one, query
from app.utils.devices import client_ip, device_label, is_phone

APPROVAL_TTL_MIN = 10


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def is_trusted(user_id, dev: str | None) -> bool:
    if not dev:
        return True   # nothing to recognise the device by — don't lock people out
    return bool(await one("SELECT 1 FROM trusted_devices WHERE user_id = $1 AND device_id = $2", user_id, dev))


async def trust(user_id, dev: str | None, label: str):
    if dev:
        await query(
            """INSERT INTO trusted_devices (user_id, device_id, label) VALUES ($1, $2, $3)
               ON CONFLICT (user_id, device_id) DO UPDATE SET label = EXCLUDED.label""",
            user_id, dev, label,
        )


async def needs_approval(row: dict, dev: str | None) -> bool:
    """Does this password sign-in have to wait for the owner's OK?

    The phone is the account's main device. A computer/browser signing in
    with ID + password waits EVERY time (even a browser used before) until
    the owner accepts — on their phone, another signed-in device, or the
    email. Linking a computer by QR from the phone skips this (the phone
    approved it). A phone signing in only waits when it's new for the account.
    Nobody to ask (no other device, no email) → no wait, so nobody is locked out."""
    if not dev:
        return False
    if is_phone(dev):
        if await is_trusted(row["id"], dev):
            return False
        has_email = bool(row.get("email") and row.get("email_verified_at"))
        return has_email and bool(await one("SELECT 1 FROM trusted_devices WHERE user_id = $1 LIMIT 1", row["id"]))
    from app.utils.otp import mail_ready
    can_email = bool(row.get("email") and row.get("email_verified_at") and (mail_ready() or config.OTP_DEV_MODE))
    other_device = await one(
        "SELECT 1 FROM trusted_devices WHERE user_id = $1 AND device_id <> $2 LIMIT 1", row["id"], dev,
    )
    return can_email or bool(other_device)


async def pending_for(user_id) -> list[dict]:
    """Open sign-in requests for this account — a phone that was closed when
    one arrived asks for these when it opens."""
    rows = await query(
        f"""SELECT id, label, ip, created_at FROM login_approvals
             WHERE user_id = $1 AND status = 'pending'
               AND created_at > now() - interval '{APPROVAL_TTL_MIN} minutes'
             ORDER BY created_at DESC LIMIT 5""",
        user_id,
    )
    return [{"id": str(r["id"]), "device": r["label"], "ip": r["ip"], "createdAt": r["created_at"].isoformat()} for r in rows]


def _public_base(request: Request) -> str:
    """Where the Accept / Reject links in the email point: the API as this
    client reached it, unless PUBLIC_API_URL says otherwise."""
    return (config.PUBLIC_API_URL or str(request.base_url)).rstrip("/")


def _mask(email: str) -> str:
    name, _, domain = email.partition("@")
    return f"{name[:2]}{'•' * max(2, len(name) - 2)}@{domain}"


def _send_mail(to: str, label: str, ip: str | None, approve_url: str, reject_url: str):
    msg = EmailMessage()
    msg["Subject"] = "Is this you signing in to Veyon Chat?"
    msg["From"] = f"Veyon Chat <{config.MAIL_FROM}>"
    msg["To"] = to
    where = f"{label}{f' ({ip})' if ip else ''}"
    msg.set_content(
        f"Someone is trying to sign in to your Veyon Chat account on {where}.\n\n"
        f"If it's you, accept: {approve_url}\n"
        f"If it isn't you, reject: {reject_url}\n\n"
        f"The request expires in {APPROVAL_TTL_MIN} minutes. If it wasn't you, also change your password."
    )
    btn = "display:inline-block;padding:12px 22px;border-radius:99px;font-weight:700;text-decoration:none;font-size:15px"
    msg.add_alternative(f"""\
<div style="font-family:Segoe UI,Arial,sans-serif;max-width:440px;margin:auto;padding:24px;color:#1c1b19">
  <div style="font-size:18px;font-weight:700;color:#4263eb">Veyon Chat</div>
  <p style="font-size:16px;font-weight:600;margin:18px 0 6px">Is this you signing in?</p>
  <p style="font-size:14px;color:#57534e;margin:0 0 18px">Someone is trying to sign in to your account on
     <b>{html.escape(where)}</b>.</p>
  <a href="{approve_url}" style="{btn};background:#4263eb;color:#fff">Yes, it's me — accept</a>
  &nbsp;
  <a href="{reject_url}" style="{btn};background:#f1f0ed;color:#c92a2a">No — reject</a>
  <p style="font-size:12.5px;color:#8f8a84;margin-top:22px">The request expires in {APPROVAL_TTL_MIN} minutes.
     If it wasn't you, reject it and change your password.</p>
</div>""", subtype="html")
    with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=20) as smtp:
        smtp.starttls()
        smtp.login(config.SMTP_USER, config.SMTP_PASS)
        smtp.send_message(msg)


async def start(row: dict, dev: str, request: Request) -> dict:
    """Creates the pending request, emails the owner and alerts their open
    devices. Returns what the waiting device is told."""
    from app.utils.otp import mail_ready
    from app.websocket import manager as hub

    token = secrets.token_urlsafe(32)
    label = device_label(request)
    ip = client_ip(request)
    # One open request per device at a time.
    await query("UPDATE login_approvals SET status = 'rejected', decided_at = now() "
                "WHERE user_id = $1 AND device_id = $2 AND status = 'pending'", row["id"], dev)
    req = await one(
        """INSERT INTO login_approvals (user_id, device_id, label, ip, token_hash)
           VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at""",
        row["id"], dev, label, ip, _hash(token),
    )
    base = _public_base(request)
    approve_url = f"{base}/api/auth/login-approval?token={token}&action=approve"
    reject_url = f"{base}/api/auth/login-approval?token={token}&action=reject"

    out = {"pending": True, "approvalId": str(req["id"]), "email": _mask(row["email"])}
    emailed = False
    if mail_ready():
        try:
            await asyncio.to_thread(_send_mail, row["email"], label, ip, approve_url, reject_url)
            emailed = True
        except Exception as err:  # noqa: BLE001 — still approvable from a signed-in device
            print(f"[login-approval] email failed: {err!r}")
    elif config.OTP_DEV_MODE:
        out["devApproveUrl"] = approve_url   # local testing without email set up
    out["emailed"] = emailed

    await hub.notify_user(row["id"], {
        "type": "login-approval",
        "approval": {"id": str(req["id"]), "device": label, "ip": ip, "createdAt": req["created_at"]},
    })
    return out


async def decide(approval: dict, approve: bool):
    await query(
        "UPDATE login_approvals SET status = $2, decided_at = now() WHERE id = $1 AND status = 'pending'",
        approval["id"], "approved" if approve else "rejected",
    )


async def find_open(where_sql: str, value) -> dict | None:
    """A request that is still pending and not expired."""
    return await one(
        f"""SELECT * FROM login_approvals WHERE {where_sql} AND status = 'pending'
              AND created_at > now() - interval '{APPROVAL_TTL_MIN} minutes'""",
        value,
    )


def page(title: str, text: str, ok: bool) -> str:
    color = "#2b8a3e" if ok else "#c92a2a"
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{html.escape(title)}</title></head>
<body style="font-family:Segoe UI,Arial,sans-serif;background:#f3f2ef;margin:0;display:grid;place-items:center;min-height:100vh">
<div style="background:#fff;border-radius:24px;padding:32px 28px;max-width:380px;text-align:center;box-shadow:0 10px 30px -12px rgba(0,0,0,.18)">
<div style="font-size:18px;font-weight:700;color:#4263eb">Veyon Chat</div>
<h2 style="color:{color};margin:18px 0 8px">{html.escape(title)}</h2>
<p style="color:#57534e;font-size:15px;line-height:1.5">{html.escape(text)}</p></div></body></html>"""
