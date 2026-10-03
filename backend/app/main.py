"""API + WebSocket server. The frontend is served separately (../frontend).

Run from the backend/ folder with:
  python run.py                         (HTTP :4000 + HTTPS :4443 when certs/ exist)
  uvicorn app.main:app --port 4000      (single plain listener, handy for local testing)
"""
import asyncio
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.v1.router import api_router
from app.core import database as db
from app.core.config import CERT_DIR, CORS_ORIGIN_REGEX, CORS_ORIGINS, HTTPS_PORT, PORT, PROJECT_DIR, UPLOAD_DIR
from app.core.database import close_pool, init_pool
from app.schedulers.reminders_scheduler import run_reminder_scheduler
from app.schedulers.scheduled_messages_scheduler import run_scheduled_messages_poller
from app.websocket import manager as hub

STATUS_SWEEP_S = 60 * 60  # housekeeping only — every read already filters by expires_at

_background_tasks: list[asyncio.Task] = []


async def _status_sweep_loop():
    while True:
        await asyncio.sleep(STATUS_SWEEP_S)
        try:
            await db.pool.execute("DELETE FROM statuses WHERE expires_at <= now()")
        except Exception as err:  # noqa: BLE001
            print(f"[status-sweep] {err!r}")


EXPIRY_SWEEP_S = 60  # disappearing messages: reads already hide expired rows


async def _expiry_sweep_loop():
    """Deletes disappearing messages (and their encrypted files) for good
    once they expire — reads filter them out before this runs anyway."""
    while True:
        await asyncio.sleep(EXPIRY_SWEEP_S)
        try:
            rows = await db.pool.fetch(
                "DELETE FROM messages WHERE expires_at <= now() RETURNING file_path"
            )
            for r in rows:
                if r["file_path"]:
                    (Path(UPLOAD_DIR) / Path(r["file_path"]).name).unlink(missing_ok=True)
        except Exception as err:  # noqa: BLE001
            print(f"[expiry-sweep] {err!r}")


async def _apply_schema_file():
    """Runs database/postgres/schema.sql — every statement in it is
    idempotent, so new tables/columns arrive with a plain restart."""
    sql_file = PROJECT_DIR / "database" / "postgres" / "schema.sql"
    if sql_file.exists():
        await db.pool.execute(sql_file.read_text(encoding="utf-8"))


async def _schema_top_up():
    """Lightweight auto-migration, idempotent — so the theming/appearance and
    device-linking features work without a manual migration step."""
    await db.pool.execute(
        """ALTER TABLE users ADD COLUMN IF NOT EXISTS appearance jsonb NOT NULL
             DEFAULT '{"palette":"veyon","mode":"dark","structure":"floating"}'::jsonb"""
    )
    # ADD COLUMN IF NOT EXISTS is a no-op on a database that already has this
    # column (e.g. the existing production DB, previously defaulted to
    # 'aurora') — it doesn't update an existing column's DEFAULT. This makes
    # the rebrand's new default actually take effect there too, for any
    # future insert that doesn't specify appearance explicitly.
    await db.pool.execute(
        """ALTER TABLE users ALTER COLUMN appearance
             SET DEFAULT '{"palette":"veyon","mode":"dark","structure":"floating"}'::jsonb"""
    )
    await db.pool.execute(
        """CREATE TABLE IF NOT EXISTS link_requests (
             code                 text PRIMARY KEY,
             device_secret_hash   text NOT NULL,
             ephemeral_public_key jsonb NOT NULL,
             user_id              uuid REFERENCES users(id) ON DELETE CASCADE,
             wrapped_key          text,
             wrapped_iv           text,
             status               text NOT NULL DEFAULT 'pending'
                                    CHECK (status IN ('pending', 'ready', 'used')),
             created_at           timestamptz NOT NULL DEFAULT now(),
             expires_at           timestamptz NOT NULL DEFAULT (now() + interval '3 minutes')
           )"""
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    Path(UPLOAD_DIR).mkdir(parents=True, exist_ok=True)
    await init_pool()

    try:
        async with db.pool.acquire() as conn:
            await conn.execute("SELECT 1")
    except Exception as err:
        raise RuntimeError(
            f"Cannot reach PostgreSQL: {err}\n"
            "  Check that the server is running and your .env values are right,\n"
            "  then create the schema with:  python setup_db.py"
        ) from err

    try:
        await _schema_top_up()
    except Exception as err:  # noqa: BLE001
        print(f"[migrate] schema top-up failed: {err!r}")
    try:
        await _apply_schema_file()
    except Exception as err:  # noqa: BLE001
        print(f"[migrate] schema.sql failed: {err!r}")

    _background_tasks.append(asyncio.create_task(run_reminder_scheduler()))
    _background_tasks.append(asyncio.create_task(run_scheduled_messages_poller()))
    _background_tasks.append(asyncio.create_task(_status_sweep_loop()))
    _background_tasks.append(asyncio.create_task(_expiry_sweep_loop()))

    yield

    for t in _background_tasks:
        t.cancel()
    await close_pool()


app = FastAPI(lifespan=lifespan)

# The frontend lives on another origin, so the browser needs CORS — with
# credentials, because the session is a cookie.
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_origin_regex=CORS_ORIGIN_REGEX,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """Every route raises HTTPException(status, "message"), but FastAPI's
    default body is {"detail": ...}. The frontend's api() helper reads
    response.error, so reshape to {"error": ...} — otherwise every error
    would lose its message and show a generic "Request failed (status)"."""
    return JSONResponse(status_code=exc.status_code, content={"error": exc.detail})


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(status_code=422, content={"error": "Malformed request."})


app.include_router(api_router)


@app.get("/")
async def root():
    return {"name": "chat-application API", "health": "/api/health"}


@app.get("/api/presence")
async def presence():
    return {"online": hub.online_user_ids()}


@app.get("/api/health")
async def health():
    try:
        async with db.pool.acquire() as conn:
            await conn.execute("SELECT 1")
        return {"ok": True}
    except Exception as err:  # noqa: BLE001
        return JSONResponse(status_code=503, content={"ok": False, "error": str(err)})


def _origin_allowed(origin: str) -> bool:
    if origin.rstrip("/") in CORS_ORIGINS:
        return True
    return bool(CORS_ORIGIN_REGEX and re.fullmatch(CORS_ORIGIN_REGEX, origin))


@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    # CORS doesn't cover WebSockets, and the browser attaches the session
    # cookie to the handshake — so check Origin here, or any site the user
    # visits could open an authenticated socket as them.
    origin = websocket.headers.get("origin")
    if origin and not _origin_allowed(origin):
        await websocket.close(code=4003, reason="Origin not allowed")
        return
    await hub.handle_connection(websocket)


async def run_dual_listener():
    import uvicorn

    cert_path = CERT_DIR / "cert.pem"
    key_path = CERT_DIR / "key.pem"

    http_config = uvicorn.Config(app, host="0.0.0.0", port=PORT, log_level="info")
    servers = [uvicorn.Server(http_config)]

    if cert_path.exists() and key_path.exists():
        https_config = uvicorn.Config(
            app, host="0.0.0.0", port=HTTPS_PORT, log_level="info",
            ssl_certfile=str(cert_path), ssl_keyfile=str(key_path),
        )
        servers.append(uvicorn.Server(https_config))
    else:
        print("\n  No TLS cert at backend/certs/ — LAN/HTTPS access disabled.\n")

    print(f"\n  API running at http://localhost:{PORT}\n")
    if len(servers) > 1:
        print(f"  LAN/HTTPS API at https://<this-pc's-lan-ip>:{HTTPS_PORT}\n")
    if not CORS_ORIGINS and not CORS_ORIGIN_REGEX:
        print("  WARNING: CORS_ORIGINS is empty — the frontend won't be able to call this API.\n")

    await asyncio.gather(*(s.serve() for s in servers))
