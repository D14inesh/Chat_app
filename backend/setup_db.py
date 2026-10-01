"""Creates the database if it doesn't exist, then applies
../database/postgres/schema.sql. Safe to re-run — every statement in the
schema is IF NOT EXISTS.

  python setup_db.py
"""
import asyncio
import sys

import asyncpg

from app.core.config import PG, PROJECT_DIR

SCHEMA_PATH = PROJECT_DIR / "database" / "postgres" / "schema.sql"


async def main():
    base = {k: PG[k] for k in ("host", "port", "user", "password")}
    db_name = PG["database"]

    # You can't CREATE DATABASE from inside the database you're creating.
    try:
        admin = await asyncpg.connect(**base, database="postgres")
    except Exception as err:  # noqa: BLE001
        print(f"\n  Could not connect to PostgreSQL at {base['host']}:{base['port']}\n  {err}\n", file=sys.stderr)
        sys.exit(1)

    exists = await admin.fetchval("SELECT 1 FROM pg_database WHERE datname = $1", db_name)
    if exists:
        print(f'  Database "{db_name}" already exists')
    else:
        await admin.execute(f'CREATE DATABASE "{db_name.replace(chr(34), chr(34) * 2)}"')
        print(f'  Created database "{db_name}"')
    await admin.close()

    conn = await asyncpg.connect(**base, database=db_name)
    await conn.execute(SCHEMA_PATH.read_text(encoding="utf-8"))
    await conn.close()
    print("  Schema applied.\n  Now run:  python run.py\n")


if __name__ == "__main__":
    asyncio.run(main())
