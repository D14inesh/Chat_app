"""Redis: what every API worker shares.

Nginx spreads users over several API workers (separate processes), so one
person's phone can be connected to worker A while the friend they message is
on worker B. Everything that used to live in a single process's memory goes
through here instead:

  • events  — "send this frame to user X's sockets" is published on one Redis
              channel; every worker delivers it to the sockets it holds.
  • presence — who is online, across all workers (expires on its own if a
              worker dies, so nobody stays "online" forever).
  • shared  — small shared tables (ringing calls, group call seats).
  • limits  — counters for rate limits (wrong PIN tries, ...).
  • leader  — exactly one worker runs the background jobs (backups,
              scheduled messages, clean-ups).

With no REDIS_URL (local development) all of it falls back to this process's
memory, which is exactly how the app worked as a single process.
"""
import asyncio
import json
import time
import uuid

from app.core.config import REDIS_URL

WORKER = uuid.uuid4().hex[:10]
CHANNEL = "veyon:events"
PRESENCE_TTL_S = 45       # a worker that stops heartbeating drops out after this
HEARTBEAT_S = 15
LEADER_TTL_S = 30

redis = None               # redis.asyncio.Redis when REDIS_URL is set
_on_event = None           # set by the WebSocket hub: async fn(event dict)
_local_users: dict[str, int] = {}   # user -> sockets open on THIS worker
_tasks: list[asyncio.Task] = []

# In-memory stand-ins used when there's no Redis.
_mem_hash: dict[str, dict[str, str]] = {}
_mem_counts: dict[str, tuple[int, float]] = {}


def enabled() -> bool:
    return redis is not None


def on_event(handler):
    global _on_event
    _on_event = handler


async def start():
    """Connect (when configured) and start listening. Fails loudly: a worker
    that can't reach Redis would silently miss everyone else's messages."""
    global redis
    if not REDIS_URL:
        return
    import redis.asyncio as aioredis
    redis = aioredis.from_url(REDIS_URL, decode_responses=True, health_check_interval=30)
    try:
        await redis.ping()
    except Exception as err:
        raise RuntimeError(f"Cannot reach Redis at REDIS_URL: {err}") from err
    ready = asyncio.Event()
    _tasks.append(asyncio.create_task(_listen(ready)))
    _tasks.append(asyncio.create_task(_heartbeat()))
    await asyncio.wait_for(ready.wait(), 10)
    print(f"  [bus] worker {WORKER} connected to Redis")


async def stop():
    for t in _tasks:
        t.cancel()
    if redis is not None:
        try:
            await redis.zrem("veyon:workers", WORKER)
            for user in list(_local_users):
                await redis.zrem(f"veyon:on:{user}", WORKER)
            await redis.aclose()
        except Exception:  # noqa: BLE001 — shutting down anyway
            pass


# ── Events ───────────────────────────────────────────────────

async def publish(event: dict):
    """Every worker (this one too) gets `event`."""
    if redis is None:
        if _on_event:
            await _on_event(event)
        return
    await redis.publish(CHANNEL, json.dumps(event))


async def _listen(ready: asyncio.Event):
    while True:
        pubsub = redis.pubsub(ignore_subscribe_messages=True)
        try:
            await pubsub.subscribe(CHANNEL)
            ready.set()
            async for item in pubsub.listen():
                if item.get("type") != "message" or not _on_event:
                    continue
                try:
                    await _on_event(json.loads(item["data"]))
                except Exception as err:  # noqa: BLE001 — one bad event must not stop the listener
                    print(f"[bus] event failed: {err!r}")
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001 — Redis restarted: reconnect
            print(f"[bus] listener lost Redis ({err!r}), reconnecting")
            await asyncio.sleep(2)
        finally:
            try:
                await pubsub.aclose()
            except Exception:  # noqa: BLE001
                pass


# ── Presence ─────────────────────────────────────────────────
# veyon:on:<user> is a sorted set of the workers holding that user's
# sockets, scored by when the entry expires. veyon:online is the same for
# "all online users" — so a crashed worker's users simply age out.

async def socket_opened(user_id: str) -> bool:
    """Count a new socket. True when this is the user's first one anywhere
    (they just came online)."""
    _local_users[user_id] = _local_users.get(user_id, 0) + 1
    if redis is None:
        return _local_users[user_id] == 1
    until = time.time() + PRESENCE_TTL_S
    pipe = redis.pipeline()
    pipe.zadd(f"veyon:on:{user_id}", {WORKER: until})
    pipe.zadd("veyon:online", {user_id: until})
    pipe.zcount(f"veyon:on:{user_id}", time.time(), "+inf")
    *_, workers = await pipe.execute()
    return _local_users[user_id] == 1 and workers == 1


async def socket_closed(user_id: str) -> bool:
    """Count a closed socket. True when that was their last one anywhere
    (they just went offline)."""
    left = _local_users.get(user_id, 0) - 1
    if left > 0:
        _local_users[user_id] = left
        return False
    _local_users.pop(user_id, None)
    if redis is None:
        return True
    key = f"veyon:on:{user_id}"
    await redis.zrem(key, WORKER)
    if await redis.zcount(key, time.time(), "+inf"):
        return False
    await redis.zrem("veyon:online", user_id)
    return True


def online_here(user_id: str) -> bool:
    return user_id in _local_users


async def online_among(user_ids) -> set[str]:
    ids = [str(u) for u in user_ids]
    if redis is None:
        return {u for u in ids if u in _local_users}
    now = time.time()
    pipe = redis.pipeline()
    for u in ids:
        pipe.zcount(f"veyon:on:{u}", now, "+inf")
    counts = await pipe.execute()
    return {u for u, n in zip(ids, counts) if n}


async def is_online(user_id: str) -> bool:
    return bool(await online_among([user_id]))


async def online_user_ids() -> list[str]:
    if redis is None:
        return list(_local_users)
    return list(await redis.zrangebyscore("veyon:online", time.time(), "+inf"))


async def _heartbeat():
    while True:
        try:
            until = time.time() + PRESENCE_TTL_S
            pipe = redis.pipeline()
            pipe.zadd("veyon:workers", {WORKER: until})
            for user in list(_local_users):
                pipe.zadd(f"veyon:on:{user}", {WORKER: until})
                pipe.zadd("veyon:online", {user: until})
            pipe.zremrangebyscore("veyon:online", "-inf", time.time())
            await pipe.execute()
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001
            print(f"[bus] heartbeat failed: {err!r}")
        await asyncio.sleep(HEARTBEAT_S)


# ── Shared tables (Redis hashes) ─────────────────────────────

async def hget(name: str, key: str) -> str | None:
    if redis is None:
        return _mem_hash.get(name, {}).get(key)
    return await redis.hget(name, key)


async def hset(name: str, key: str, value: str):
    if redis is None:
        _mem_hash.setdefault(name, {})[key] = value
        return
    await redis.hset(name, key, value)


async def hdel(name: str, key: str):
    if redis is None:
        table = _mem_hash.get(name)
        if table is not None:
            table.pop(key, None)
            if not table:
                del _mem_hash[name]
        return
    await redis.hdel(name, key)


async def hgetall(name: str) -> dict[str, str]:
    if redis is None:
        return dict(_mem_hash.get(name, {}))
    return await redis.hgetall(name)


class _NoLock:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


_local_locks: dict[str, asyncio.Lock] = {}


def lock(name: str, timeout: float = 10):
    """A lock every worker respects (just a local one without Redis)."""
    if redis is None:
        return _local_locks.setdefault(name, asyncio.Lock())
    return redis.lock(f"veyon:lock:{name}", timeout=timeout, blocking_timeout=timeout)


# ── Rate limits ──────────────────────────────────────────────

async def hits(key: str) -> int:
    """How many times `key` was counted in its current window."""
    if redis is None:
        n, until = _mem_counts.get(key, (0, 0.0))
        return n if until > time.time() else 0
    return int(await redis.get(f"veyon:rate:{key}") or 0)


async def hit(key: str, window_s: int) -> int:
    """Count one more; the window starts at the first hit."""
    if redis is None:
        n, until = _mem_counts.get(key, (0, 0.0))
        if until <= time.time():
            n, until = 0, time.time() + window_s
        _mem_counts[key] = (n + 1, until)
        return n + 1
    k = f"veyon:rate:{key}"
    pipe = redis.pipeline()
    pipe.incr(k)
    pipe.expire(k, window_s, nx=True)
    n, _ = await pipe.execute()
    return int(n)


async def clear(key: str):
    if redis is None:
        _mem_counts.pop(key, None)
        return
    await redis.delete(f"veyon:rate:{key}")


# ── Leader (one worker runs the background jobs) ─────────────

async def run_as_leader(start_jobs):
    """Keeps trying to become the leader; while it is, the jobs started by
    start_jobs() run here. Loses leadership (e.g. Redis hiccup) → stops them,
    so two workers never send the same scheduled message twice."""
    if redis is None:
        start_jobs()
        return
    jobs: list[asyncio.Task] = []
    key = "veyon:leader"
    while True:
        try:
            if jobs:
                still = await redis.eval(
                    "if redis.call('get', KEYS[1]) == ARGV[1] then "
                    "return redis.call('expire', KEYS[1], ARGV[2]) else return 0 end",
                    1, key, WORKER, LEADER_TTL_S,
                )
                if not still:
                    print(f"[bus] worker {WORKER} lost leadership, stopping background jobs")
                    for t in jobs:
                        t.cancel()
                    jobs = []
            elif await redis.set(key, WORKER, nx=True, ex=LEADER_TTL_S):
                print(f"[bus] worker {WORKER} runs the background jobs")
                jobs = start_jobs()
        except asyncio.CancelledError:
            for t in jobs:
                t.cancel()
            raise
        except Exception as err:  # noqa: BLE001
            print(f"[bus] leader check failed: {err!r}")
        await asyncio.sleep(LEADER_TTL_S / 3)


async def status() -> dict:
    if redis is None:
        return {"redis": "off", "worker": WORKER}
    try:
        await redis.ping()
        workers = await redis.zcount("veyon:workers", time.time(), "+inf")
        return {"redis": "ok", "worker": WORKER, "workers": workers}
    except Exception as err:  # noqa: BLE001
        return {"redis": f"error: {err}", "worker": WORKER}
