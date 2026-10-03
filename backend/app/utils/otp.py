"""Mobile number + email (Gmail) verification for accounts.

Every account has a mobile number and an email, each usable by one account
only. The email is proven with a 6-digit code sent to it; the number is
checked for shape and uniqueness (proving it would need paid SMS)."""
import asyncio
import hashlib
import hmac
import re
import secrets
import smtplib
from email.message import EmailMessage

from fastapi import HTTPException

from app.core import config
from app.core.database import one, query

CODE_TTL_MIN = 10
MAX_TRIES = 5
RESEND_AFTER_S = 45
MAX_PER_HOUR = 6

_EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def normalize_phone(raw) -> str | None:
    """'98765 43210' / '+91-98765-43210' / '919876543210' → '+919876543210'.
    Other countries need the + and country code."""
    s = re.sub(r"[\s\-().]", "", str(raw or ""))
    if re.fullmatch(r"0?[6-9]\d{9}", s):
        return "+91" + s[-10:]
    if re.fullmatch(r"91[6-9]\d{9}", s):
        return "+" + s
    if re.fullmatch(r"\+\d{8,15}", s):
        return s
    return None


def normalize_email(raw) -> str | None:
    s = str(raw or "").strip().lower()
    return s if len(s) <= 254 and _EMAIL_RE.match(s) else None


def read_contact(body: dict) -> tuple[str, str]:
    phone = normalize_phone(body.get("phone"))
    if not phone:
        raise HTTPException(400, "Enter a valid mobile number (10 digits, or + and country code).")
    email = normalize_email(body.get("email"))
    if not email:
        raise HTTPException(400, "Enter a valid email address (your Gmail).")
    return phone, email


async def ensure_contact_free(phone: str, email: str, except_user: str | None = None):
    """One account per mobile number and per email."""
    row = await one(
        """SELECT phone = $1 AS phone_hit FROM users
            WHERE (phone = $1 OR lower(email) = $2) AND ($3::uuid IS NULL OR id <> $3::uuid)
            LIMIT 1""",
        phone, email, except_user,
    )
    if row:
        what = "mobile number" if row["phone_hit"] else "email"
        raise HTTPException(409, f"That {what} is already used by another account. One account per {what}.")


def _hash(email: str, code: str) -> str:
    return hmac.new(config.JWT_SECRET.encode(), f"{email}:{code}".encode(), hashlib.sha256).hexdigest()


def mail_ready() -> bool:
    return bool(config.SMTP_USER and config.SMTP_PASS)


def _send_mail(to: str, code: str):
    msg = EmailMessage()
    msg["Subject"] = f"{code} is your Veyon Chat code"
    msg["From"] = f"Veyon Chat <{config.MAIL_FROM}>"
    msg["To"] = to
    msg.set_content(
        f"Your Veyon Chat verification code is {code}\n\n"
        f"It expires in {CODE_TTL_MIN} minutes. If you didn't ask for it, ignore this email."
    )
    msg.add_alternative(f"""\
<div style="font-family:Segoe UI,Arial,sans-serif;max-width:420px;margin:auto;padding:24px;color:#1f2430">
  <div style="font-size:18px;font-weight:700;color:#6C5CE7">Veyon Chat</div>
  <p style="font-size:15px">Your verification code is</p>
  <div style="font-size:34px;font-weight:800;letter-spacing:8px;padding:14px 0;color:#111">{code}</div>
  <p style="font-size:13px;color:#666">It expires in {CODE_TTL_MIN} minutes. If you didn't ask for it, you can ignore this email.</p>
</div>""", subtype="html")
    with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=20) as smtp:
        smtp.starttls()
        smtp.login(config.SMTP_USER, config.SMTP_PASS)
        smtp.send_message(msg)


async def send_code(phone: str, email: str, purpose: str) -> dict:
    """Emails a fresh code. Returns {sent: True} (+ devCode in dev mode)."""
    if not mail_ready() and not config.OTP_DEV_MODE:
        raise HTTPException(503, "Email codes aren't set up on the server yet — ask the admin to add the Gmail settings.")

    recent = await one(
        """SELECT count(*) AS n, max(created_at) > now() - make_interval(secs => $2) AS too_soon
             FROM email_otps WHERE lower(email) = $1 AND created_at > now() - interval '1 hour'""",
        email, RESEND_AFTER_S,
    )
    if recent["too_soon"]:
        raise HTTPException(429, f"A code was just sent — wait {RESEND_AFTER_S} seconds before asking again.")
    if recent["n"] >= MAX_PER_HOUR:
        raise HTTPException(429, "Too many codes for this email. Try again in an hour.")

    code = f"{secrets.randbelow(1_000_000):06d}"
    await query(
        """INSERT INTO email_otps (email, phone, purpose, code_hash, expires_at)
           VALUES ($1, $2, $3, $4, now() + make_interval(mins => $5))""",
        email, phone, purpose, _hash(email, code), CODE_TTL_MIN,
    )
    if mail_ready():
        try:
            await asyncio.to_thread(_send_mail, email, code)
        except Exception as err:  # noqa: BLE001
            print(f"[otp] email to {email} failed: {err!r}")
            raise HTTPException(502, "Couldn't send the email. Check the address and try again.")
        return {"sent": True}
    print(f"[otp] DEV MODE code for {email}: {code}")
    return {"sent": True, "devCode": code}


async def check_code(phone: str, email: str, purpose: str, code) -> None:
    """Consumes the latest matching code or raises 400."""
    code = re.sub(r"\D", "", str(code or ""))
    row = await one(
        """SELECT id, code_hash, attempts, expires_at > now() AS live FROM email_otps
            WHERE lower(email) = $1 AND phone = $2 AND purpose = $3 AND used_at IS NULL
            ORDER BY created_at DESC LIMIT 1""",
        email, phone, purpose,
    )
    if not row or not row["live"]:
        raise HTTPException(400, "That code has expired — tap “Send code” for a new one.")
    if row["attempts"] >= MAX_TRIES:
        raise HTTPException(400, "Too many wrong tries — tap “Send code” for a new one.")
    if len(code) != 6 or not hmac.compare_digest(row["code_hash"], _hash(email, code)):
        await query("UPDATE email_otps SET attempts = attempts + 1 WHERE id = $1", row["id"])
        left = MAX_TRIES - row["attempts"] - 1
        raise HTTPException(400, f"Wrong code. {left} tr{'y' if left == 1 else 'ies'} left." if left else
                            "Wrong code. Tap “Send code” for a new one.")
    await query("UPDATE email_otps SET used_at = now() WHERE id = $1", row["id"])
