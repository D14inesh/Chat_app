"""This app's own small database (data/report.db, SQLite): saved settings,
the admin password hash and a log of what the owner did. The chat
application's database is never written to."""
import json
import secrets
import sqlite3
import threading
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent / "data"
DATA_DIR.mkdir(exist_ok=True)
_lock = threading.Lock()
_db = sqlite3.connect(DATA_DIR / "report.db", check_same_thread=False)
_db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
_db.execute("""CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL, detail TEXT, ip TEXT,
    at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')))""")
_db.commit()


def get(key: str, default=None):
    with _lock:
        row = _db.execute("SELECT value FROM kv WHERE key = ?", (key,)).fetchone()
    return json.loads(row[0]) if row else default


def put(key: str, value):
    with _lock:
        _db.execute("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    (key, json.dumps(value)))
        _db.commit()


def delete(key: str):
    with _lock:
        _db.execute("DELETE FROM kv WHERE key = ?", (key,))
        _db.commit()


def all_settings() -> dict:
    return get("settings", {}) or {}


def jwt_secret() -> str:
    s = get("_jwt")
    if not s:
        s = secrets.token_hex(48)
        put("_jwt", s)
    return s


def log(action: str, detail: str = "", ip: str = ""):
    with _lock:
        _db.execute("INSERT INTO audit (action, detail, ip) VALUES (?, ?, ?)", (action, detail[:300], ip))
        _db.commit()


def recent_log(n: int = 30) -> list[dict]:
    with _lock:
        rows = _db.execute("SELECT action, detail, ip, at FROM audit ORDER BY id DESC LIMIT ?", (n,)).fetchall()
    return [{"action": a, "detail": d, "ip": i, "at": t} for a, d, i, t in rows]
