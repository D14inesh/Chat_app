"""Env-driven config — same variable names and defaults as the original
chatapp .env, plus the settings the split frontend/backend needs (CORS,
cookie SameSite, storage location)."""
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parents[2]  # backend/
PROJECT_DIR = BACKEND_DIR.parent                   # chat-application/
load_dotenv(BACKEND_DIR / ".env")

CERT_DIR = BACKEND_DIR / "certs"

# Files live outside the code, in chat-application/storage/ by default.
STORAGE_DIR = Path(os.environ.get("STORAGE_DIR") or (PROJECT_DIR / "storage"))
# Opaque AES-GCM blobs the browser already encrypted (attachments, voice, status media).
UPLOAD_DIR = STORAGE_DIR / "uploads"
# Plain, directly-viewable profile photos.
AVATAR_DIR = STORAGE_DIR / "avatars"
WALLPAPER_DIR = STORAGE_DIR / "wallpapers"

# The frontend is served separately, so the browser calls this API
# cross-origin. List every origin the frontend is opened from, comma-separated:
#   CORS_ORIGINS=http://localhost:5173,https://localhost:5443
# CORS_ORIGIN_REGEX additionally allows a pattern (e.g. any LAN IP).
CORS_ORIGINS = [o.strip().rstrip("/") for o in os.environ.get("CORS_ORIGINS", "").split(",") if o.strip()]
CORS_ORIGIN_REGEX = os.environ.get("CORS_ORIGIN_REGEX", "").strip() or None

# "lax" works when frontend and backend share a host on different ports
# (localhost:5173 -> localhost:4000 is still same-site). Frontend and backend
# on different domains need "none", which browsers only accept with Secure —
# so the backend must then be reached over HTTPS.
COOKIE_SAMESITE = os.environ.get("COOKIE_SAMESITE", "lax").strip().lower()
if COOKIE_SAMESITE not in ("lax", "strict", "none"):
    COOKIE_SAMESITE = "lax"

PORT = int(os.environ.get("PORT", "4000"))
# LAN/phone access needs HTTPS — WebCrypto (crypto.subtle) only runs in a
# browser "secure context" on https:// or literal localhost, not a plain
# http:// LAN IP. See backend/certs/.
HTTPS_PORT = int(os.environ.get("HTTPS_PORT", "4443"))
SESSION_TTL = os.environ.get("SESSION_TTL", "7d")
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(100 * 1024 * 1024)))

# AI Chat — Ollama, local, no API key.
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434/api/chat")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.2")

# Voice-to-text — separate local Whisper service.
WHISPER_URL = os.environ.get("WHISPER_URL", "http://localhost:8500")

# GIF search — Tenor.
TENOR_API_KEY = os.environ.get("TENOR_API_KEY", "")

# Reminders — Web Push (VAPID).
VAPID_PUBLIC_KEY = os.environ.get("VAPID_PUBLIC_KEY", "")
VAPID_PRIVATE_KEY = os.environ.get("VAPID_PRIVATE_KEY", "")
VAPID_SUBJECT = os.environ.get("VAPID_SUBJECT", "mailto:admin@example.com")

JWT_SECRET = os.environ.get("JWT_SECRET")

# Fail loudly at boot rather than silently signing every session with
# "undefined"/None, which would let anyone forge a token.
if not JWT_SECRET or len(JWT_SECRET) < 32 or JWT_SECRET == "replace-me-with-a-long-random-string":
    print(
        "\n  JWT_SECRET is missing or still the placeholder.\n"
        "  Copy .env.example to .env, then generate one with:\n"
        "    python -c \"import secrets; print(secrets.token_hex(48))\"\n",
        file=sys.stderr,
    )
    sys.exit(1)

PG = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": int(os.environ.get("PGPORT", "5432")),
    "user": os.environ.get("PGUSER", "postgres"),
    "password": os.environ.get("PGPASSWORD", ""),
    "database": os.environ.get("PGDATABASE", "vesper_chat"),
}

# Sign-up codes — emailed through any SMTP account. For Gmail: turn on
# 2-step verification, create an App Password (myaccount.google.com →
# Security → App passwords) and put it in SMTP_PASS.
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
MAIL_FROM = os.environ.get("MAIL_FROM", "") or SMTP_USER
# Local testing without email: the code is returned to the app and shown
# on screen. Never turn this on for the real server.
OTP_DEV_MODE = os.environ.get("OTP_DEV_MODE", "").strip().lower() in ("1", "true", "yes")

# Daily database backups (pg_dump custom format), made by the backend itself
# once a day after BACKUP_HOUR (server time); the newest BACKUP_KEEP are kept.
BACKUP_DIR = Path(os.environ.get("BACKUP_DIR") or (PROJECT_DIR / "database" / "backups"))
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "7"))
BACKUP_HOUR = int(os.environ.get("BACKUP_HOUR", "2"))
# Full path to pg_dump.exe when it isn't found automatically.
PG_BIN = os.environ.get("PG_BIN", "")
