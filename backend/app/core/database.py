"""asyncpg pool + query helpers — mirrors src/db.js. Deliberately raw SQL (no
ORM): several routes rely on specific Postgres idioms (multi-CTE aggregates,
`ON CONFLICT DO UPDATE SET col = EXCLUDED.col` as a no-op-update-to-fetch-the-
row trick, atomic conditional `UPDATE ... WHERE ... RETURNING`) that port far
more reliably as SQL text than through a query builder.

asyncpg already uses $1, $2, ... positional placeholders — the same as
node-postgres — so query strings carry over near verbatim from the JS files.
"""
import json
from contextlib import asynccontextmanager

import asyncpg

from app.core.config import PG

pool: asyncpg.Pool | None = None


async def _init_connection(conn: asyncpg.Connection):
    # asyncpg returns jsonb/json columns as raw text by default — every column
    # that's jsonb in schema.sql (users.public_key, .enc_private_key,
    # .appearance, link_requests.ephemeral_public_key, ...) needs this to come
    # back as a Python dict/list, matching what node-postgres's `pg` driver
    # already does automatically for the Node app.
    await conn.set_type_codec(
        "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
    )
    await conn.set_type_codec(
        "json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
    )
    # asyncpg's default `uuid` codec returns Python uuid.UUID objects, not
    # plain str — every id/senderId/conversationId/userId in this schema is a
    # uuid column, and code throughout this port (session JWTs, membership
    # list comparisons, JSON responses) treats them as strings, matching how
    # node-postgres's `pg` driver already returns them for the Node app. This
    # codec makes asyncpg do the same, rather than special-casing UUID
    # conversion at every call site.
    await conn.set_type_codec(
        "uuid", encoder=str, decoder=str, schema="pg_catalog", format="text"
    )


async def init_pool():
    global pool
    pool = await asyncpg.create_pool(
        host=PG["host"], port=PG["port"], user=PG["user"],
        password=PG["password"], database=PG["database"],
        min_size=1, max_size=10, init=_init_connection,
    )
    return pool


async def close_pool():
    if pool is not None:
        await pool.close()


def _row_to_dict(row: asyncpg.Record | None):
    return dict(row) if row is not None else None


async def query(text: str, *params):
    """Returns a list of dicts (plain rows), like node-postgres's `{ rows }`."""
    async with pool.acquire() as conn:
        rows = await conn.fetch(text, *params)
        return [dict(r) for r in rows]


async def one(text: str, *params):
    """Returns the first row as a dict, or None."""
    async with pool.acquire() as conn:
        row = await conn.fetchrow(text, *params)
        return _row_to_dict(row)


async def execute(text: str, *params) -> str:
    """Returns the raw asyncpg status string (e.g. 'UPDATE 3') — use when only
    the affected-row COUNT matters (mirrors node-postgres's `rowCount`)."""
    async with pool.acquire() as conn:
        return await conn.execute(text, *params)


def row_count(status: str) -> int:
    """asyncpg's execute() returns 'UPDATE 3' / 'DELETE 1' / 'INSERT 0 1' — the
    trailing integer is the row count, mirroring node-postgres's `rowCount`."""
    return int(status.rsplit(" ", 1)[-1])


@asynccontextmanager
async def transaction():
    """`async with transaction() as conn:` — runs on a single connection inside
    a BEGIN/COMMIT, rolling back if the block raises. Mirrors db.js's
    transaction(fn)."""
    async with pool.acquire() as conn:
        async with conn.transaction():
            yield conn


async def is_blocked_either_way(user_a: str, user_b: str) -> bool:
    """True if either user has blocked the other — deliberately direction-
    agnostic, the shared check used everywhere two people are about to be
    connected (a message, a call, a new direct conversation)."""
    row = await one(
        """SELECT 1 FROM blocked_users
             WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)""",
        user_a, user_b,
    )
    return row is not None


async def are_accepted_contacts(user_id: str, other_ids: list[str]) -> bool:
    """True only if EVERY id in other_ids is an existing ACCEPTED direct
    contact of user_id. Used identically by group creation and status
    posting in the Node app (previously two copy-pasted queries there) —
    consolidated here into the one shared helper the plan calls for."""
    if not other_ids:
        return True
    rows = await query(
        """SELECT cm2.user_id
             FROM conversation_members cm1
             JOIN conversation_members cm2 ON cm2.conversation_id = cm1.conversation_id AND cm2.user_id <> cm1.user_id
             JOIN conversations c ON c.id = cm1.conversation_id
            WHERE cm1.user_id = $1 AND c.kind = 'direct' AND c.status = 'accepted'
              AND cm2.user_id = ANY($2::uuid[])""",
        user_id, other_ids,
    )
    found = {r["user_id"] for r in rows}
    return found == set(other_ids)
