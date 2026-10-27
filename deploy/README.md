# Server layout

```
Users ──► Nginx ──┬──► API worker 1 (FastAPI: HTTP API + WebSocket) ──┐
                  ├──► API worker 2                                   ├──► Redis
                  └──► ...                                            └──► PostgreSQL
```

The same layout runs on two kinds of server:

- **Ubuntu (recommended for production):** see [ubuntu/README.md](ubuntu/README.md).
  It uses systemd, free trusted HTTPS, has no connection limit, and updates
  without downtime.
- **Windows** (this page): `scripts\setup-server.ps1` installs and wires it
  up; `scripts\update-server.ps1` pulls new code and re-runs it.

| Piece | Where | Reachable from |
|---|---|---|
| Nginx 1.30 | `runtime\nginx-*` | internet: 5843/5800 (website + API), 4843/4800 (API, phone app) |
| API workers | `backend\` (`python run.py`, one per port) | 127.0.0.1:4810, 4811, … |
| Redis 8 | `runtime\redis-*` | 127.0.0.1:6379 (password in `backend\.env` → `REDIS_URL`) |
| PostgreSQL | installed separately | as before |

`runtime\` is generated (ignored by git); the templates live in `deploy\nginx\`.

## What each part does

- **Nginx** is the only door. It does HTTPS (certificate from
  `backend\certs`), serves the website files straight from
  `web\public`, and forwards `/api` and `/ws` to the workers, spreading
  connections over them (`least_conn`). If a worker is down it uses the others.
- **API workers** are the same FastAPI app as before, several copies side by
  side. Each holds only its own users' live sockets.
- **Redis** lets the workers act as one app:
  - a message for someone connected to another worker is published to
    Redis, and the worker holding their socket delivers it;
  - who is online (expires on its own if a worker dies);
  - ringing 1:1 calls and group call seats;
  - "log out other devices" closes sockets on every worker, and old tokens
    stop working on every worker;
  - shared rate limits (wrong chat-lock PIN tries);
  - one worker is the **leader** and runs the background jobs (daily
    backups, scheduled messages, clean-ups). If it dies, another takes over
    within ~30 s.

  Redis holds no messages or files, only live state that rebuilds itself as
  people reconnect, so it keeps nothing on disk.
- **PostgreSQL** stores everything permanent, as before.

## Day to day

- Logs: `logs\backend-4810.log`, `logs\backend-4811.log`, `logs\redis.log`,
  `logs\nginx.log`; Nginx's request log is in `runtime\nginx-*\logs\access.log`.
- Health: `http://127.0.0.1:5800/api/health` shows
  `{"ok": true, "redis": "ok", "workers": 2}`.
- Everything restarts by itself after a crash (each piece runs in a loop) and
  at boot (scheduled task "Chat application").
- More workers: `scripts\setup-server.ps1 -Workers 4`. Roughly one per CPU
  core is the useful maximum.

## Limits, and what comes next

Nginx for Windows handles at most **1024 connections at once**, and each
online user's live socket uses two (browser→Nginx, Nginx→worker). That's
about **500 people online at the same moment**, which is plenty for now.
Past that, run the same layout on Linux, where Nginx has no such limit. The
backend code doesn't change: point `REDIS_URL` at the Redis server and put
more API servers behind Nginx.

## Development

Locally nothing changes: with no `REDIS_URL`, a single `python run.py` keeps
the shared state in its own memory, and `web\serve.py` serves the site.
