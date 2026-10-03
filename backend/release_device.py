"""Admin tool for the one-account-per-device rule.

    python release_device.py                 list every locked device
    python release_device.py <username>      list that user's devices
    python release_device.py <username> --release-all
                                             free all of that user's devices
                                             (e.g. they lost their phone)
"""
import asyncio
import sys

from app.core import database as db


async def main(args: list[str]):
    await db.init_pool()
    try:
        username = args[0].lower() if args else None
        sql = """SELECT b.device_id, b.label, b.created_at, b.last_seen, u.username
                   FROM device_bindings b JOIN users u ON u.id = b.user_id"""
        rows = (await db.query(sql + " WHERE u.username_lower = $1 ORDER BY b.last_seen DESC", username)
                if username else await db.query(sql + " ORDER BY u.username, b.last_seen DESC"))
        if not rows:
            print("No locked devices" + (f" for @{username}." if username else "."))
            return
        for r in rows:
            print(f"@{r['username']:<20} {r['label'] or 'Device':<28} since {r['created_at']:%Y-%m-%d}  "
                  f"last seen {r['last_seen']:%Y-%m-%d %H:%M}  [{r['device_id'][:16]}…]")
        if username and "--release-all" in args:
            status = await db.execute(
                "DELETE FROM device_bindings WHERE user_id = (SELECT id FROM users WHERE username_lower = $1)",
                username,
            )
            print(f"Released {db.row_count(status)} device(s) for @{username}.")
    finally:
        await db.close_pool()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
