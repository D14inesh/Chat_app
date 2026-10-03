"""Restores the database from a backup made by the backend.

    python restore_backup.py                      list backups
    python restore_backup.py <file.dump> --yes    restore that backup

Stop the backend first. Everything in the database is replaced by the
backup's contents (uploaded files in storage\\ are not touched)."""
import os
import subprocess
import sys
from pathlib import Path

from app.core import config
from app.utils.backup import list_backups, pg_tool


def main(args: list[str]):
    if not args:
        rows = list_backups()
        if not rows:
            print(f"No backups in {config.BACKUP_DIR}")
        for b in rows:
            print(f"{b['name']:<40} {b['size'] // 1024:>8} KB   {b['createdAt'][:16].replace('T', ' ')}")
        return
    path = Path(args[0])
    if not path.exists():
        path = Path(config.BACKUP_DIR) / args[0]
    if not path.exists():
        sys.exit(f"Backup not found: {args[0]}")
    if "--yes" not in args:
        sys.exit(f"This replaces everything in database '{config.PG['database']}' with {path.name}.\n"
                 f"Stop the backend, then run again with --yes to go ahead.")
    exe = pg_tool("pg_restore")
    if not exe:
        sys.exit("pg_restore wasn't found — set PG_BIN in backend\\.env to your PostgreSQL bin folder.")
    env = {**os.environ, "PGPASSWORD": config.PG["password"]}
    result = subprocess.run(
        [exe, "--clean", "--if-exists", "--no-owner", "-h", config.PG["host"], "-p", str(config.PG["port"]),
         "-U", config.PG["user"], "-d", config.PG["database"], str(path)],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(result.stderr[-2000:])
        sys.exit("Restore finished with errors (see above).")
    print(f"Restored {path.name}. Start the backend again.")


if __name__ == "__main__":
    main(sys.argv[1:])
