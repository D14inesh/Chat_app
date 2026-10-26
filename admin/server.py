"""Chat Report Center — a separate app for the chat application's owner.

  * Reports: users, activity, calls, AI use, email, storage (read-only view of
    the chat database — the connection is opened read-only, nothing is written).
  * Settings: sender email + app password, AI key, "Hey ARM" voice prompt.
    Saved in this app's own data/report.db, never in the chat application.

Run:  python server.py     then open  http://localhost:4700
"""
import asyncio
import base64
import csv
import hmac
import io
import json
import os
import platform
import re
import smtplib
import ssl
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path

import asyncpg
import bcrypt
import jwt
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse

import ai
import store

HERE = Path(__file__).resolve().parent
load_dotenv(HERE / ".env")

PORT = int(os.environ.get("PORT", "4700"))
HOST = os.environ.get("HOST", "127.0.0.1")
PG = dict(host=os.environ.get("PGHOST", "localhost"), port=int(os.environ.get("PGPORT", "5432")),
          user=os.environ.get("PGUSER", "postgres"), password=os.environ.get("PGPASSWORD", ""),
          database=os.environ.get("PGDATABASE", "vesper_chat"))
CHAT_STORAGE = Path(os.environ.get("CHAT_STORAGE_DIR") or (HERE.parent / "storage"))
CHAT_BACKUPS = Path(os.environ.get("CHAT_BACKUP_DIR") or (HERE.parent / "database" / "backups"))
# App name + logo the owner chooses. Written here, read by the chat API
# (GET /api/branding) and by this app's own pages, so every page shows them.
BRAND_DIR = CHAT_STORAGE / "branding"
BRAND_FILE = BRAND_DIR / "brand.json"
DEFAULT_APP_NAME = "Veyon Chat"
LOGO_TYPES = {b"\x89PNG\r\n\x1a\n": ("png", "image/png"), b"\xff\xd8\xff": ("jpg", "image/jpeg"),
              b"RIFF": ("webp", "image/webp"), b"GIF8": ("gif", "image/gif")}
MAX_LOGO_BYTES = 1024 * 1024
COOKIE = "report_admin"
SESSION_HOURS = 8
STARTED = time.time()
JWT = store.jwt_secret()

DEFAULT_VOICE_PROMPT = (
    "You are ARM, the voice assistant inside Veyon Chat. Answer in one or two short, natural spoken "
    "sentences. No lists, no markdown, no emojis. Reply in the language the user spoke."
)
SECRETS = {"smtp_pass", "ai_key"}
FIELDS = {"smtp_host": str, "smtp_port": int, "smtp_user": str, "smtp_pass": str, "mail_from_name": str,
          "mail_from": str, "owner_email": str, "ai_provider": str, "ai_key": str, "ai_model": str,
          "ai_base_url": str, "voice_enabled": bool, "voice_prompt": str, "voice_max_words": int}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# ───────────────────────── chat database (read-only) ─────────────────────────
_pool: asyncpg.Pool | None = None
_pool_failed_at = 0.0


async def pool() -> asyncpg.Pool:
    global _pool, _pool_failed_at
    if _pool:
        return _pool
    if time.time() - _pool_failed_at < 5:
        raise RuntimeError("The chat database is not reachable.")
    try:
        _pool = await asyncpg.create_pool(**PG, min_size=1, max_size=4, timeout=6,
                                          server_settings={"default_transaction_read_only": "on",
                                                           "application_name": "chat_application_report"})
        await _pool.execute("SELECT 1")
        return _pool
    except Exception as err:  # noqa: BLE001
        _pool = None
        _pool_failed_at = time.time()
        raise RuntimeError(f"Cannot reach the chat database ({type(err).__name__}). Check the PG settings in .env.") from None


async def q(sql: str, *args) -> list[dict]:
    p = await pool()
    return [dict(r) for r in await p.fetch(sql, *args)]


async def q1(sql: str, *args) -> dict | None:
    rows = await q(sql, *args)
    return rows[0] if rows else None


@asynccontextmanager
async def lifespan(app):
    yield
    if _pool:
        await _pool.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.exception_handler(HTTPException)
async def _http(request, exc):
    return JSONResponse(status_code=exc.status_code, content={"error": exc.detail})


@app.exception_handler(RequestValidationError)
async def _val(request, exc):
    return JSONResponse(status_code=422, content={"error": "Malformed request."})


@app.middleware("http")
async def _guard(request: Request, call_next):
    # Same-site only for anything that changes state (cookie is SameSite=strict as well).
    if request.method in ("POST", "PUT", "DELETE"):
        origin = request.headers.get("origin")
        if origin and origin.split("://", 1)[-1] != request.headers.get("host"):
            return JSONResponse(status_code=403, content={"error": "Blocked: request from another site."})
    resp = await call_next(request)
    resp.headers.setdefault("Cache-Control", "no-store")
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    return resp


# ───────────────────────────── admin sign-in ─────────────────────────────
_fails: dict[str, list[float]] = {}


BEHIND_PROXY = os.environ.get("BEHIND_PROXY") == "1"


def ip_of(request: Request) -> str:
    # Behind Nginx the socket peer is always 127.0.0.1; the visitor is in X-Real-IP.
    if BEHIND_PROXY and request.headers.get("x-real-ip"):
        return request.headers["x-real-ip"]
    return request.client.host if request.client else "?"


def is_local(request: Request) -> bool:
    if BEHIND_PROXY:
        return False   # reached through the public site: never offer first-visit setup
    return ip_of(request) in ("127.0.0.1", "::1")


def env_password() -> str:
    return os.environ.get("ADMIN_PASSWORD", "")


def configured() -> bool:
    return bool(env_password() or store.get("_pw"))


def check_password(pw: str) -> bool:
    env = env_password()
    if env:
        return hmac.compare_digest(env.encode(), pw.encode())
    h = store.get("_pw")
    return bool(h) and bcrypt.checkpw(pw.encode()[:72], h.encode())


def new_hash(pw: str) -> str:
    if len(pw) < 8:
        raise HTTPException(400, "Use at least 8 characters.")
    return bcrypt.hashpw(pw.encode()[:72], bcrypt.gensalt()).decode()


def issue(response: Response, request: Request):
    tok = jwt.encode({"adm": 1, "exp": int(time.time()) + SESSION_HOURS * 3600}, JWT, algorithm="HS256")
    response.set_cookie(COOKIE, tok, max_age=SESSION_HOURS * 3600, httponly=True, samesite="strict",
                        secure=request.url.scheme == "https", path="/")


def authed(request: Request) -> bool:
    try:
        return bool(jwt.decode(request.cookies.get(COOKIE) or "", JWT, algorithms=["HS256"]).get("adm"))
    except jwt.PyJWTError:
        return False


async def need_admin(request: Request):
    if not authed(request):
        raise HTTPException(401, "Please sign in.")


@app.get("/")
async def index():
    return FileResponse(HERE / "static" / "index.html", headers={
        "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                                   "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"})


@app.get("/api/session")
async def session(request: Request):
    return {"configured": configured(), "authed": authed(request), "canSetup": is_local(request)}


@app.post("/api/setup")
async def setup(request: Request, response: Response):
    if configured():
        raise HTTPException(409, "The password is already set.")
    if not is_local(request):
        raise HTTPException(403, "First-time setup must be done on this PC (open http://localhost:%d), or set ADMIN_PASSWORD in .env." % PORT)
    body = await request.json()
    store.put("_pw", new_hash(str(body.get("password") or "")))
    issue(response, request)
    store.log("setup", "admin password created", ip_of(request))
    return {"ok": True}


@app.post("/api/login")
async def login(request: Request, response: Response):
    ip, now = ip_of(request), time.time()
    recent = [t for t in _fails.get(ip, []) if now - t < 600]
    if len(recent) >= 6:
        raise HTTPException(429, "Too many wrong passwords. Wait 10 minutes.")
    body = await request.json()
    if not configured() or not check_password(str(body.get("password") or "")):
        _fails[ip] = recent + [now]
        await asyncio.sleep(0.6)
        raise HTTPException(401, "Wrong password.")
    _fails.pop(ip, None)
    issue(response, request)
    store.log("login", "", ip)
    return {"ok": True}


@app.post("/api/logout")
async def logout(response: Response):
    response.delete_cookie(COOKIE, path="/")
    return {"ok": True}


@app.post("/api/password", dependencies=[Depends(need_admin)])
async def change_password(request: Request):
    if env_password():
        raise HTTPException(409, "The password comes from ADMIN_PASSWORD in .env — change it there.")
    body = await request.json()
    if not check_password(str(body.get("current") or "")):
        raise HTTPException(401, "Current password is wrong.")
    store.put("_pw", new_hash(str(body.get("new") or "")))
    store.log("password-changed", "", ip_of(request))
    return {"ok": True}


# ───────────────────────────── app name + logo ─────────────────────────────
def read_brand() -> dict:
    try:
        b = json.loads(BRAND_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        b = {}
    logo = b.get("logo")
    if not logo or not (BRAND_DIR / logo).is_file():
        logo = None
    return {"name": b.get("name") or DEFAULT_APP_NAME, "logo": logo, "v": int(b.get("v") or 0)}


def write_brand(name: str, logo: str | None):
    BRAND_DIR.mkdir(parents=True, exist_ok=True)
    BRAND_FILE.write_text(json.dumps({"name": name, "logo": logo, "v": int(time.time())}), encoding="utf-8")


def brand_json() -> dict:
    b = read_brand()
    return {"name": b["name"], "logoUrl": f"/api/branding/logo?v={b['v']}" if b["logo"] else None, "v": b["v"]}


@app.get("/api/branding")
async def get_branding():
    return brand_json()


@app.get("/api/branding/logo")
async def get_logo():
    b = read_brand()
    if not b["logo"]:
        raise HTTPException(404, "No logo.")
    ext = b["logo"].rsplit(".", 1)[-1]
    mime = next(m for e, m in LOGO_TYPES.values() if e == ext)
    return FileResponse(BRAND_DIR / b["logo"], media_type=mime)


@app.post("/api/branding", dependencies=[Depends(need_admin)])
async def set_branding(request: Request):
    body = await request.json()
    b = read_brand()
    if "name" in body:
        name = re.sub(r"\s+", " ", str(body.get("name") or "")).strip()[:40]
        if not name:
            raise HTTPException(400, "Give the app a name.")
        b["name"] = name
    if body.get("removeLogo"):
        if b["logo"]:
            (BRAND_DIR / b["logo"]).unlink(missing_ok=True)
        b["logo"] = None
    elif body.get("logo"):
        try:
            raw = base64.b64decode(str(body["logo"]).split(",", 1)[-1], validate=True)
        except ValueError:
            raise HTTPException(400, "That image could not be read.") from None
        if len(raw) > MAX_LOGO_BYTES:
            raise HTTPException(400, "Logo is too big — use an image under 1 MB.")
        kind = next((v for k, v in LOGO_TYPES.items() if raw.startswith(k)), None)
        if not kind or (kind[0] == "webp" and raw[8:12] != b"WEBP"):
            raise HTTPException(400, "Use a PNG, JPG, WebP or GIF image.")
        BRAND_DIR.mkdir(parents=True, exist_ok=True)
        if b["logo"]:
            (BRAND_DIR / b["logo"]).unlink(missing_ok=True)
        b["logo"] = f"logo.{kind[0]}"
        (BRAND_DIR / b["logo"]).write_bytes(raw)
    write_brand(b["name"], b["logo"])
    store.log("branding", f"name={b['name']} logo={'yes' if b['logo'] else 'no'}", ip_of(request))
    return brand_json()


# ───────────────────────────────── settings ─────────────────────────────────
def hint(v: str) -> str:
    return "••••" + v[-4:] if len(v) > 8 else "••••••••"


def public_settings() -> dict:
    s, out = store.all_settings(), {}
    for k, typ in FIELDS.items():
        v = s.get(k)
        if k in SECRETS:
            out[k] = {"set": bool(v), "hint": hint(v) if v else ""}
        elif typ is bool:
            out[k] = v is not False if k == "voice_enabled" else bool(v)
        else:
            out[k] = v if v not in (None, "") else ("" if typ is str else None)
    out["default_voice_prompt"] = DEFAULT_VOICE_PROMPT
    return out


@app.get("/api/settings", dependencies=[Depends(need_admin)])
async def get_settings():
    return public_settings()


@app.put("/api/settings", dependencies=[Depends(need_admin)])
async def put_settings(request: Request):
    body, s, touched = await request.json(), store.all_settings(), []
    for k, typ in FIELDS.items():
        if k not in body:
            continue
        v = body[k]
        if k in SECRETS and v == "":
            continue  # blank = keep what is saved
        if v is None:
            s.pop(k, None)
        elif typ is bool:
            s[k] = bool(v)
        elif typ is int:
            if str(v).strip() == "":
                s.pop(k, None)
            else:
                try:
                    s[k] = int(v)
                except ValueError:
                    raise HTTPException(400, f"{k.replace('_', ' ').capitalize()} must be a number.")
        else:
            v = str(v).strip()[:2000]
            s.pop(k, None) if not v else s.__setitem__(k, v)
        touched.append(k)
    for f in ("smtp_user", "mail_from", "owner_email"):
        if s.get(f) and not EMAIL_RE.match(s[f]):
            raise HTTPException(400, f"“{s[f]}” is not a valid email address.")
    if s.get("ai_provider") and s["ai_provider"] not in ai.DEFAULTS:
        raise HTTPException(400, "Unknown AI provider.")
    if s.get("ai_base_url") and not re.match(r"^https?://", s["ai_base_url"]):
        raise HTTPException(400, "The base URL must start with http:// or https://")
    if s.get("voice_max_words") is not None and not 5 <= s["voice_max_words"] <= 200:
        raise HTTPException(400, "Voice reply length must be between 5 and 200 words.")
    store.put("settings", s)
    store.log("settings-saved", ", ".join(sorted(touched)) or "nothing", ip_of(request))  # names only, never values
    return public_settings()


def smtp_ready(s: dict) -> bool:
    return bool(s.get("smtp_user") and s.get("smtp_pass"))


def send_mail(s: dict, to: str, subject: str, text: str):
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"{s.get('mail_from_name') or read_brand()['name']} <{s.get('mail_from') or s['smtp_user']}>"
    msg["To"] = to
    msg.set_content(text)
    host, port = s.get("smtp_host") or "smtp.gmail.com", int(s.get("smtp_port") or 587)
    if port == 465:
        with smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context()) as smtp:
            smtp.login(s["smtp_user"], s["smtp_pass"].replace(" ", ""))
            smtp.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=20) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(s["smtp_user"], s["smtp_pass"].replace(" ", ""))
            smtp.send_message(msg)


async def deliver(to: str, subject: str, text: str):
    s = store.all_settings()
    if not EMAIL_RE.match(to or ""):
        raise HTTPException(400, "Enter the address to send to (or save an owner email).")
    if not smtp_ready(s):
        raise HTTPException(400, "Save the sender email and its app password first.")
    try:
        await asyncio.to_thread(send_mail, s, to, subject, text)
    except smtplib.SMTPAuthenticationError:
        raise HTTPException(502, "The mail server refused the login. For Gmail use an App Password, not your normal password.")
    except Exception as err:  # noqa: BLE001
        raise HTTPException(502, f"Could not send: {type(err).__name__}: {str(err)[:160]}")


@app.post("/api/test-email", dependencies=[Depends(need_admin)])
async def test_email(request: Request):
    body = await request.json()
    to = str(body.get("to") or store.all_settings().get("owner_email") or "").strip()
    await deliver(to, f"{read_brand()['name']} — test email", "Your sender email and app password work.")
    store.log("test-email", to, ip_of(request))
    return {"ok": True, "message": f"Sent to {to}. Check the inbox (and spam)."}


@app.post("/api/test-ai", dependencies=[Depends(need_admin)])
async def test_ai(request: Request):
    body, s = await request.json(), store.all_settings()
    t0 = time.time()
    try:
        reply = await ai.chat(s, "", str(body.get("prompt") or "Say hello in one short sentence.")[:500], max_tokens=120)
    except ai.AIError as err:
        raise HTTPException(502, str(err))
    store.log("test-ai", s.get("ai_provider", ""), ip_of(request))
    return {"ok": True, "reply": reply, "ms": int((time.time() - t0) * 1000)}


@app.post("/api/test-voice", dependencies=[Depends(need_admin)])
async def test_voice(request: Request):
    """Try the 'Hey ARM' replier: type what a user would say, see what ARM answers."""
    body, s = await request.json(), store.all_settings()
    text = str(body.get("text") or "").strip()[:600]
    if not text:
        raise HTTPException(400, "Type something ARM should answer.")
    words = int(s.get("voice_max_words") or 40)
    try:
        reply = await ai.chat(s, f"{s.get('voice_prompt') or DEFAULT_VOICE_PROMPT}\nKeep it under {words} words.", text)
    except ai.AIError as err:
        raise HTTPException(502, str(err))
    return {"reply": reply}


@app.get("/api/env-lines", dependencies=[Depends(need_admin)])
async def env_lines(request: Request):
    """The saved values as lines for the chat backend's .env (copy/paste yourself)."""
    s = store.all_settings()
    lines = ["# Paste into the chat backend's .env if you want it to use these:",
             f"SMTP_HOST={s.get('smtp_host') or 'smtp.gmail.com'}", f"SMTP_PORT={s.get('smtp_port') or 587}",
             f"SMTP_USER={s.get('smtp_user', '')}", f"SMTP_PASS={(s.get('smtp_pass') or '').replace(' ', '')}",
             f"MAIL_FROM={s.get('mail_from') or s.get('smtp_user', '')}"]
    store.log("copy-env-lines", "", ip_of(request))
    return PlainTextResponse("\n".join(lines))


# ───────────────────────────────── reports ─────────────────────────────────
async def series(table: str, col: str, days: int, where: str = "") -> list[dict]:
    rows = await q(
        f"""SELECT d::date AS day, count(t.*) AS n
              FROM generate_series(current_date - ($1::int - 1), current_date, interval '1 day') d
              LEFT JOIN {table} t ON t.{col}::date = d::date {('AND ' + where) if where else ''}
             GROUP BY 1 ORDER BY 1""", days)
    return [{"day": r["day"].isoformat(), "n": r["n"]} for r in rows]


def dir_stats(path: Path) -> dict:
    n = size = 0
    try:
        for e in os.scandir(path):
            if e.is_file():
                n += 1
                size += e.stat().st_size
    except OSError:
        pass
    return {"files": n, "bytes": size}


_storage_cache: tuple[float, dict] | None = None


async def storage() -> dict:
    global _storage_cache
    if _storage_cache and time.time() - _storage_cache[0] < 120:
        return _storage_cache[1]
    out = {k: await asyncio.to_thread(dir_stats, CHAT_STORAGE / d)
           for k, d in (("uploads", "uploads"), ("avatars", "avatars"), ("chatBackups", "chat_backups"))}
    _storage_cache = (time.time(), out)
    return out


def db_backups() -> list[dict]:
    try:
        files = sorted(CHAT_BACKUPS.glob("*.dump"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return []
    return [{"name": f.name, "bytes": f.stat().st_size,
             "at": datetime.fromtimestamp(f.stat().st_mtime, timezone.utc).isoformat()} for f in files[:6]]


async def safe(fn):
    try:
        return await fn()
    except Exception as err:  # noqa: BLE001 — one failing section must not blank the page
        return {"error": f"{str(err)[:150]}"}


async def build_overview() -> dict:
    async def users():
        r = await q1("""SELECT count(*) AS total,
              count(*) FILTER (WHERE created_at > now() - interval '1 day')   AS new_1d,
              count(*) FILTER (WHERE created_at > now() - interval '7 days')  AS new_7d,
              count(*) FILTER (WHERE created_at > now() - interval '30 days') AS new_30d,
              count(*) FILTER (WHERE last_seen > now() - interval '5 minutes') AS online,
              count(*) FILTER (WHERE last_seen > now() - interval '1 day')    AS active_1d,
              count(*) FILTER (WHERE last_seen > now() - interval '7 days')   AS active_7d,
              count(*) FILTER (WHERE last_seen > now() - interval '30 days')  AS active_30d,
              count(*) FILTER (WHERE email_verified_at IS NOT NULL) AS email_verified,
              count(*) FILTER (WHERE phone IS NOT NULL) AS with_phone,
              count(*) FILTER (WHERE disabled_at IS NOT NULL) AS disabled
            FROM users""")
        r["phone_app"] = (await q1("SELECT count(DISTINCT user_id) AS n FROM device_bindings WHERE device_id NOT LIKE 'web:%'"))["n"]
        r["web"] = (await q1("SELECT count(DISTINCT user_id) AS n FROM trusted_devices WHERE device_id LIKE 'web:%'"))["n"]
        r["signups"] = await series("users", "created_at", 30)
        rows = await q("""SELECT d::date AS day, count(DISTINCT e.user_id) AS n
                            FROM generate_series(current_date - 13, current_date, interval '1 day') d
                            LEFT JOIN login_events e ON e.created_at::date = d::date GROUP BY 1 ORDER BY 1""")
        r["activeByDay"] = [{"day": x["day"].isoformat(), "n": x["n"]} for x in rows]
        return r

    async def messages():
        r = await q1("""SELECT count(*) AS total,
              count(*) FILTER (WHERE created_at > now() - interval '1 day')  AS d1,
              count(*) FILTER (WHERE created_at > now() - interval '7 days') AS d7,
              coalesce(sum(file_size), 0) AS file_bytes
            FROM messages WHERE deleted_at IS NULL""")
        r["byKind"] = await q("SELECT kind, count(*) AS n FROM messages WHERE deleted_at IS NULL GROUP BY kind ORDER BY n DESC")
        r["perDay"] = await series("messages", "created_at", 14, "t.deleted_at IS NULL")
        r.update(await q1("SELECT count(*) FILTER (WHERE kind='direct') AS direct, count(*) FILTER (WHERE kind='group') AS groups FROM conversations"))
        r["statusesLive"] = (await q1("SELECT count(*) AS n FROM statuses WHERE expires_at > now()"))["n"]
        return r

    async def calls():
        r = await q1("""SELECT count(*) AS total,
              count(*) FILTER (WHERE started_at > now() - interval '1 day') AS d1,
              count(*) FILTER (WHERE call_type = 'video') AS video,
              coalesce(avg(extract(epoch FROM ended_at - answered_at))
                       FILTER (WHERE answered_at IS NOT NULL AND ended_at IS NOT NULL), 0)::int AS avg_secs
            FROM call_logs""")
        r["byStatus"] = await q("SELECT status, count(*) AS n FROM call_logs GROUP BY status ORDER BY n DESC")
        r["perDay"] = await series("call_logs", "started_at", 14)
        return r

    async def email():
        r = await q1("""SELECT count(*) FILTER (WHERE created_at > now() - interval '1 day')  AS sent_1d,
              count(*) FILTER (WHERE created_at > now() - interval '7 days') AS sent_7d,
              count(*) FILTER (WHERE created_at > now() - interval '7 days' AND used_at IS NOT NULL) AS used_7d
            FROM email_otps""")
        r["perDay"] = await series("email_otps", "created_at", 14)
        return r

    async def ai_use():
        r = await q1("""SELECT count(*) FILTER (WHERE role = 'user') AS questions,
              count(*) FILTER (WHERE role = 'user' AND created_at > now() - interval '1 day') AS q_1d,
              count(DISTINCT user_id) FILTER (WHERE created_at > now() - interval '30 days') AS users_30d
            FROM ai_messages""")
        r["perDay"] = await series("ai_messages", "created_at", 14, "t.role = 'user'")
        return r

    async def other():
        return {
            "pushDevices": (await q1("SELECT count(*) AS n FROM push_subscriptions"))["n"],
            "remindersPending": (await q1("SELECT count(*) AS n FROM reminders WHERE notified_at IS NULL"))["n"],
            "scheduledPending": (await q1("SELECT count(*) AS n FROM scheduled_messages WHERE sent_at IS NULL"))["n"],
            "cloudBackups": await q1("SELECT count(*) AS n, coalesce(sum(size),0) AS bytes FROM chat_backups"),
            "dbBytes": (await q1("SELECT pg_database_size(current_database()) AS n"))["n"],
        }

    async def system():
        s = store.all_settings()
        await pool()
        return {"uptimeSecs": int(time.time() - STARTED), "python": platform.python_version(), "os": platform.system(),
                "mail": {"ready": smtp_ready(s), "user": s.get("smtp_user", "")},
                "ai": {"ready": ai.ready(s), "provider": s.get("ai_provider", ""), "model": ai.model_for(s) if ai.ready(s) else ""},
                "voice": {"enabled": s.get("voice_enabled", True) is not False}}

    parts = await asyncio.gather(*(safe(f) for f in (users, messages, calls, email, ai_use, other, system)))
    out = dict(zip(("users", "messages", "calls", "email", "ai", "other", "system"), parts))
    out["storage"] = await storage()
    out["dbBackups"] = db_backups()
    out["generatedAt"] = datetime.now(timezone.utc).isoformat()
    return out


@app.get("/api/overview", dependencies=[Depends(need_admin)])
async def overview():
    return await build_overview()


@app.get("/api/users", dependencies=[Depends(need_admin)])
async def user_list(q_: str = Query("", alias="q"), page: int = 0, sort: str = "new"):
    page = max(0, page)
    order = {"new": "u.created_at DESC", "seen": "u.last_seen DESC", "name": "lower(u.display_name)"}.get(sort, "u.created_at DESC")
    like = f"%{q_.strip().lower()}%" if q_.strip() else None
    where = ("WHERE ($1::text IS NULL OR lower(u.username) LIKE $1 OR lower(u.display_name) LIKE $1 "
             "OR lower(coalesce(u.email,'')) LIKE $1 OR coalesce(u.phone,'') LIKE $1)")
    try:
        total = (await q1(f"SELECT count(*) AS n FROM users u {where}", like))["n"]
        rows = await q(f"""SELECT u.username, u.display_name, u.email, u.phone, u.created_at, u.last_seen, u.disabled_at,
                   (u.email_verified_at IS NOT NULL) AS email_ok,
                   (SELECT device FROM login_events e WHERE e.user_id = u.id ORDER BY e.created_at DESC LIMIT 1) AS device
              FROM users u {where} ORDER BY {order} LIMIT 25 OFFSET $2""", like, page * 25)
    except RuntimeError as err:
        raise HTTPException(503, str(err))
    return {"total": total, "page": page, "rows": rows}


def as_csv(rows: list[dict], name: str) -> PlainTextResponse:
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:  # stop spreadsheet formulas from user-typed text
            w.writerow({k: ("'" + v if isinstance(v, str) and v[:1] in ("=", "+", "-", "@") else v) for k, v in r.items()})
    return PlainTextResponse("\ufeff" + buf.getvalue(), media_type="text/csv; charset=utf-8",
                             headers={"Content-Disposition": f'attachment; filename="{name}"'})


@app.get("/api/export/users.csv", dependencies=[Depends(need_admin)])
async def export_users(request: Request):
    rows = await q("""SELECT username, display_name, email, phone, created_at, last_seen,
                             (email_verified_at IS NOT NULL) AS email_verified, (disabled_at IS NOT NULL) AS disabled
                        FROM users ORDER BY created_at""")
    store.log("export-users", f"{len(rows)} rows", ip_of(request))
    return as_csv(rows, f"users-{datetime.now().date()}.csv")


@app.get("/api/export/daily.csv", dependencies=[Depends(need_admin)])
async def export_daily(request: Request):
    rows = await q("""SELECT d::date AS day,
          (SELECT count(*) FROM users WHERE created_at::date = d::date) AS new_users,
          (SELECT count(DISTINCT user_id) FROM login_events WHERE created_at::date = d::date) AS users_signed_in,
          (SELECT count(*) FROM messages WHERE created_at::date = d::date AND deleted_at IS NULL) AS messages,
          (SELECT count(*) FROM call_logs WHERE started_at::date = d::date) AS calls,
          (SELECT count(*) FROM ai_messages WHERE created_at::date = d::date AND role = 'user') AS ai_questions,
          (SELECT count(*) FROM email_otps WHERE created_at::date = d::date) AS emails_sent
        FROM generate_series(current_date - 89, current_date, interval '1 day') d ORDER BY 1 DESC""")
    store.log("export-daily", "", ip_of(request))
    return as_csv(rows, f"daily-report-{datetime.now().date()}.csv")


@app.post("/api/send-report", dependencies=[Depends(need_admin)])
async def send_report(request: Request):
    """Emails the owner a plain-text summary of today's numbers."""
    body = await request.json()
    to = str(body.get("to") or store.all_settings().get("owner_email") or "").strip()
    d = await build_overview()
    u, m, c, a = d["users"], d["messages"], d["calls"], d["ai"]
    if u.get("error"):
        raise HTTPException(503, u["error"])
    n = lambda x: f"{int(x or 0):,}"  # noqa: E731
    lines = [f"Chat report — {datetime.now().strftime('%d %b %Y, %I:%M %p')}", "",
             f"USERS     total {n(u['total'])} · new today {n(u['new_1d'])} · new this week {n(u['new_7d'])}",
             f"          active 24h {n(u['active_1d'])} · active 7d {n(u['active_7d'])} · active 30d {n(u['active_30d'])}",
             f"          phone app {n(u['phone_app'])} · website {n(u['web'])}"]
    if not m.get("error"):
        lines.append(f"MESSAGES  today {n(m['d1'])} · this week {n(m['d7'])} · all-time {n(m['total'])}")
    if not c.get("error"):
        lines.append(f"CALLS     today {n(c['d1'])} · all-time {n(c['total'])}")
    if not a.get("error"):
        lines.append(f"AI        questions today {n(a['q_1d'])} · all-time {n(a['questions'])}")
    await deliver(to, "Chat application — daily report", "\n".join(lines))
    store.log("send-report", to, ip_of(request))
    return {"ok": True, "message": f"Report sent to {to}."}


@app.get("/api/audit", dependencies=[Depends(need_admin)])
async def audit():
    return {"rows": store.recent_log()}


if __name__ == "__main__":
    import uvicorn
    print(f"\n  Chat Report Center is running at http://localhost:{PORT}\n")
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
