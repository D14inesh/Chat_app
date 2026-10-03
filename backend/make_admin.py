"""Gives (or takes away) access to the admin panel.

    python make_admin.py <username>            make admin
    python make_admin.py <username> --remove   remove admin
    python make_admin.py                       list admins
"""
import asyncio
import sys

from app.core import database as db


async def main(args: list[str]):
    await db.init_pool()
    try:
        if not args:
            rows = await db.query("SELECT username FROM users WHERE is_admin ORDER BY username")
            print("Admins: " + (", ".join("@" + r["username"] for r in rows) or "none yet"))
            return
        make = "--remove" not in args
        status = await db.execute("UPDATE users SET is_admin = $2 WHERE username_lower = $1", args[0].lower(), make)
        if db.row_count(status) == 0:
            sys.exit(f"No user @{args[0]}")
        print(f"@{args[0]} is {'now an admin' if make else 'no longer an admin'}. Sign out and back in to see the change.")
    finally:
        await db.close_pool()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
