"""Database backups — pg_dump in custom format, one file per run, newest
BACKUP_KEEP kept. Used by the daily loop below, the admin panel's
"Back up now", and restore_backup.py."""
import asyncio
import glob
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from app.core import config

CHECK_EVERY_S = 10 * 60
_lock = asyncio.Lock()


def pg_tool(name: str) -> str | None:
    """Finds pg_dump / pg_restore: PG_BIN's folder, PATH, then the usual
    PostgreSQL install folders on Windows."""
    if config.PG_BIN:
        base = Path(config.PG_BIN)
        cand = (base.parent if base.suffix else base) / (name + (".exe" if os.name == "nt" else ""))
        if cand.exists():
            return str(cand)
    found = shutil.which(name)
    if found:
        return found
    patterns = [rf"C:\Program Files\PostgreSQL\*\bin\{name}.exe", rf"C:\Program Files\PostgreSQL\bin\{name}.exe"]
    hits = sorted((h for p in patterns for h in glob.glob(p)), reverse=True)
    return hits[0] if hits else None


def list_backups() -> list[dict]:
    d = Path(config.BACKUP_DIR)
    if not d.exists():
        return []
    files = sorted(d.glob(f"{config.PG['database']}-*.dump"), reverse=True)
    return [{"name": f.name, "size": f.stat().st_size,
             "createdAt": datetime.fromtimestamp(f.stat().st_mtime).astimezone().isoformat()} for f in files]


def _prune():
    for old in list_backups()[config.BACKUP_KEEP:]:
        (Path(config.BACKUP_DIR) / old["name"]).unlink(missing_ok=True)


async def run_backup() -> dict:
    """Makes one backup now. Raises RuntimeError with a readable reason."""
    async with _lock:
        exe = pg_tool("pg_dump")
        if not exe:
            raise RuntimeError("pg_dump wasn't found — set PG_BIN in backend\\.env to your PostgreSQL bin folder.")
        Path(config.BACKUP_DIR).mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        target = Path(config.BACKUP_DIR) / f"{config.PG['database']}-{stamp}.dump"
        partial = target.with_suffix(".partial")
        env = {**os.environ, "PGPASSWORD": config.PG["password"]}
        # A thread, not asyncio's subprocess API — that one isn't available
        # on every Windows event loop uvicorn may run on.
        result = await asyncio.to_thread(
            subprocess.run,
            [exe, "-Fc", "-h", config.PG["host"], "-p", str(config.PG["port"]), "-U", config.PG["user"],
             "-f", str(partial), config.PG["database"]],
            env=env, capture_output=True, text=True, timeout=1800,
        )
        if result.returncode != 0:
            partial.unlink(missing_ok=True)
            raise RuntimeError(f"pg_dump failed: {result.stderr.strip()[:300]}")
        partial.replace(target)
        _prune()
        return {"name": target.name, "size": target.stat().st_size}


def _have_today() -> bool:
    today = datetime.now().strftime("%Y%m%d")
    return any(b["name"].split("-")[-2] == today for b in list_backups())


async def run_daily_backups():
    """Once a day, after BACKUP_HOUR — checked every 10 minutes, so a server
    that was off at that hour still makes the day's backup when it's back."""
    await asyncio.sleep(60)
    while True:
        try:
            if datetime.now().hour >= config.BACKUP_HOUR and not _have_today():
                info = await run_backup()
                print(f"[backup] saved {info['name']} ({info['size'] // 1024} KB)")
        except Exception as err:  # noqa: BLE001
            print(f"[backup] {err}")
        await asyncio.sleep(CHECK_EVERY_S)
