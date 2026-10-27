# ShutUp

End-to-end encrypted chat. **One repository, three apps, one shared backend.**

| Folder | What it is |
|---|---|
| `web/` | The web app (static site, no build step) |
| `mobile/` | The Flutter phone app |
| `admin/` | The owner's admin app: reports, email/AI settings, app name + logo |
| `backend/` | The single FastAPI backend (REST + WebSocket) all three use |
| `database/`, `storage/`, `deploy/`, `scripts/` | Schema + backups, uploads, server setup, start scripts |

The web app and the phone app call the backend over `/api` and `/ws`. The admin app reads the same
database (read-only) and writes the app name and logo into `storage/branding/`, which the backend
serves to the web and phone apps.

```
ShutUp/
├── web/                      static web app, no build step
│   ├── public/               the files the browser loads
│   │   ├── config.js         ← backend URL (the only file to edit when deploying)
│   │   ├── index.html
│   │   ├── sw.js             service worker (offline shell + push)
│   │   ├── manifest.json
│   │   ├── css/theme.css
│   │   ├── js/               app.js, crypto.js, localstore.js, vendor/
│   │   └── icons/
│   ├── certs/                TLS cert for LAN/HTTPS
│   └── serve.py              dev/static server (:5173 http, :5443 https)
│
├── mobile/                   Flutter phone app (see mobile/README.md)
├── admin/                    owner's admin app (python server.py, :4700)
│
├── backend/                  FastAPI — REST API + WebSocket only
│   ├── app/
│   │   ├── main.py           app assembly, CORS, /ws, startup tasks
│   │   ├── core/
│   │   │   ├── config.py     .env settings
│   │   │   ├── database.py   asyncpg pool + query helpers
│   │   │   └── security.py   JWT session cookie
│   │   ├── api/v1/           one router per feature (auth, users, conversations, …)
│   │   │   └── router.py     mounts them all
│   │   ├── websocket/
│   │   │   └── manager.py    presence, typing, messages, calls, games
│   │   ├── schedulers/       reminders, scheduled messages
│   │   └── utils/
│   │       └── serializers.py  DB row → API JSON shapes
│   ├── certs/
│   ├── run.py                start: python run.py (:4000 http, :4443 https)
│   ├── setup_db.py           create database + apply schema
│   ├── gen_cert.py           regenerate the self-signed LAN cert
│   ├── requirements.txt
│   └── .env / .env.example
│
├── database/
│   ├── postgres/schema.sql
│   └── backups/
│
├── storage/                  user files, kept out of the code folders
│   ├── uploads/              encrypted attachments / voice / status media
│   ├── avatars/              profile photos
│   └── wallpapers/           chat wallpapers
│
├── scripts/
│   ├── start-backend.ps1     auto-restarting, logs to logs/backend.log
│   ├── start-frontend.ps1    auto-restarting, logs to logs/frontend.log
│   └── start-all.vbs         starts both hidden (for the Startup folder)
└── logs/
```

## Run it

```powershell
# Backend (first time)
cd backend
python -m venv venv
.\venv\Scripts\pip install -r requirements.txt
copy .env.example .env        # then fill in PGPASSWORD, JWT_SECRET, VAPID keys
.\venv\Scripts\python setup_db.py   # only for a fresh database
.\venv\Scripts\python run.py

# Frontend (any Python 3, no packages)
cd web
python serve.py
```

Open **http://localhost:5173**. From a phone on the same Wi-Fi, open
**https://&lt;pc-lan-ip&gt;:5443**. Accept the certificate warning, and also open
https://&lt;pc-lan-ip&gt;:4443 once and accept it there, because the browser has to trust the API's certificate as well.

## How the two halves talk

- `web/public/config.js` decides where the API is. By default it uses the
  **same host as the page, port 4000 (http) or 4443 (https)**, so localhost and
  LAN IPs work with no edits. To use a separate API domain, set
  `apiBase: 'https://api.example.com'`.
- The backend only accepts browser calls from origins listed in `CORS_ORIGINS`
  (plus `CORS_ORIGIN_REGEX`) in `backend/.env`. That applies to REST and to the
  WebSocket. When you host the frontend somewhere new, add its origin there.
- Login is an HttpOnly cookie set by the backend. Frontend and backend on the
  same host with different ports works as-is (`COOKIE_SAMESITE=lax`). If they
  are on **different domains**, set `COOKIE_SAMESITE=none`, and the backend must
  be served over HTTPS.

## Docker

Frontend and backend each have their own `Dockerfile`, `.dockerignore` and
`docker-compose.yml`. Each is built and run from its own folder, independently.

```powershell
# Backend  -> http://localhost:8000   (LAN: https://<pc-ip>:8444)
cd backend
docker compose up -d --build        # or: docker build -t chat-backend .

# Frontend -> http://localhost:8080   (LAN: https://<pc-ip>:8443)
cd web
docker compose up -d --build        # or: docker build -t chat-frontend .
```

Running the images without compose:

```powershell
docker run -d --name chat-backend -p 8000:4000 -p 8444:4443 --env-file backend/.env `
  -e PGHOST=host.docker.internal -v ${PWD}/storage:/data/storage -v ${PWD}/backend/certs:/app/certs:ro chat-backend

docker run -d --name chat-frontend -p 8080:80 -p 8443:443 `
  -e API_HTTP_PORT=8000 -e API_HTTPS_PORT=8444 -v ${PWD}/web/certs:/etc/nginx/certs:ro chat-frontend
```

**Backend container**
- Settings come from `backend/.env`. Its `CORS_ORIGINS` must include the
  frontend's address; 8080/8443 are already in there.
- The database is PostgreSQL on this PC (not containerised), reached through
  `host.docker.internal`. PostgreSQL
  only accepts local connections by default, so add this line to
  `C:\Program Files\PostgreSQL\18\data\pg_hba.conf` (as admin), then restart
  the PostgreSQL service:

  ```
  host    all    all    192.168.65.0/24    scram-sha-256
  ```

  If it's still refused, `docker compose logs backend` shows the address it
  was refused from. Add that range instead.
- `../storage` is mounted at `/data/storage`, so uploads survive rebuilds.
  Set `STORAGE_PATH` to use another folder.
- `certs/` is mounted for HTTPS. Without it, the backend runs HTTP only.
- Host ports: `BACKEND_PORT` / `BACKEND_HTTPS_PORT` (default 8000 / 8444).
- For a fresh database, run `python setup_db.py` from the host; the schema
  isn't inside the image.

**Frontend container**
- nginx serving `public/`. At start, it writes `config.js` from `API_BASE`, or
  from `API_HTTP_PORT` / `API_HTTPS_PORT` (default 8000 / 8444), so the same
  image works against any backend.
- `certs/` is mounted for HTTPS. Without it, the frontend runs HTTP only.
- Host ports: `FRONTEND_PORT` / `FRONTEND_HTTPS_PORT` (default 8080 / 8443).
- Backend on another domain: set `API_BASE=https://api.example.com` here, and on
  the backend add the frontend's URL to `CORS_ORIGINS` and set
  `COOKIE_SAMESITE=none`.

Port and path variables go in a `.env` next to the `docker-compose.yml`. For the
backend, that's the same `backend/.env`.

## The server (Windows)

`scripts\setup-server.ps1` sets up Users → Nginx → API workers → Redis →
PostgreSQL on one machine; `scripts\update-server.ps1` updates it. What runs
where, logs and limits: [deploy/README.md](deploy/README.md).

## Deploying separately

- **Frontend:** upload `web/public/` to any static host (nginx, IIS,
  Netlify, …) and edit `config.js`.
- **Backend:** copy `backend/` + `database/` + `storage/`, create the venv,
  set `.env` (including `CORS_ORIGINS` = the frontend's URL), then run `python run.py`.
  `STORAGE_DIR` in `.env` can point storage somewhere else.
