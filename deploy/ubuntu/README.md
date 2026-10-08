# Veyon Chat on Ubuntu

```
Users ──► Nginx (HTTPS) ──┬──► API worker  veyon-api@4810 ──┐
                          ├──► API worker  veyon-api@4811   ├──► Redis       (live state)
                          └──► ...                          └──► PostgreSQL  (all data)
```

Tested on Ubuntu 26.04 LTS (Nginx 1.28, PostgreSQL 18, Redis 8, Python 3.14).
The script also supports 22.04 and 24.04, but use **26.04** when moving from
the Windows server: its PostgreSQL 18 matches Windows, so the Windows
backups load directly. An older PostgreSQL can't read a newer one's backups.

## What the server needs

- Ubuntu 26.04 LTS, 2+ CPU cores, 2–4 GB RAM.
- Open in the provider's firewall: **80**, **443**, and **4843** (the phone
  app's API port).
- For a trusted certificate (no browser warning): a domain name whose DNS
  **A record** points at the server, e.g. `chat.example.com`.

## Install

```bash
sudo mkdir -p /opt/veyon && sudo chown $USER /opt/veyon
git clone https://github.com/Manjuladevi0507/chat-application.git /opt/veyon/chat-application
cd /opt/veyon/chat-application

# With a domain (trusted HTTPS from Let's Encrypt, renews by itself):
sudo bash deploy/ubuntu/setup.sh --domain chat.example.com --email you@example.com
# Without a domain (self-signed HTTPS on the IP; browsers warn once):
sudo bash deploy/ubuntu/setup.sh --ip 203.0.113.10
```

Then put the email settings in `backend/.env` (`sudo nano backend/.env`):
`SMTP_USER`, `SMTP_PASS` (Gmail app password), and the `VAPID_*` keys for
push notifications. Then run `sudo systemctl restart veyon.target`. When
moving from Windows, `import-data.sh --env` copies these for you.

The setup script:
- installs Nginx, PostgreSQL, Redis and Python;
- creates the `veyon` service user and its own database user (random
  passwords);
- writes `backend/.env`;
- sets up HTTPS;
- starts one API worker per CPU core (2–8) under systemd.

Re-running it is safe: it keeps passwords, keys and data.

## Moving from the Windows server

Nothing on the Windows server changes. Copy three things from it to the
Ubuntu server (e.g. with WinSCP into `/tmp/move`):

1. The newest file in `chat-application\database\backups\`. The server makes
   one daily; it's a `vesper_chat-YYYYMMDD-HHMMSS.dump` file.
2. The `chat-application\storage` folder: photos, voice notes, avatars,
   wallpapers and backups, all already encrypted.
3. `chat-application\backend\.env`, saved as `windows.env`.

Then, on Ubuntu:

```bash
sudo bash deploy/ubuntu/import-data.sh --dump /tmp/move/vesper_chat-....dump \
     --storage /tmp/move/storage --env /tmp/move/windows.env
```

This replaces the Ubuntu database with the backup, copies the files, and
takes the old server's sign-in key (everyone stays signed in), push keys and
Gmail settings. Delete `/tmp/move` afterwards: `windows.env` holds secrets.

For the final switch, do it in a quiet hour: take a fresh backup on Windows,
import it, then point users to the new server.
- **Same IP** (or a domain that you re-point): the current phone app keeps
  working.
- **New IP or domain:** rebuild the APK for the new address.

## Day to day

| What | Command |
|---|---|
| Update to the latest code | `sudo bash deploy/ubuntu/update.sh` (workers restart one at a time, nobody is cut off) |
| Status | `systemctl status 'veyon-api@*' nginx redis-server postgresql` |
| Worker logs | `journalctl -u 'veyon-api@*' -f` |
| Nginx logs | `/var/log/nginx/access.log`, `error.log` |
| Restart the app | `sudo systemctl restart veyon.target` |
| More workers | `sudo bash deploy/ubuntu/setup.sh --workers 4` |
| Health | `curl -k https://localhost/api/health` → `{"ok":true,"redis":"ok","workers":N}` |

## Where things are

| | |
|---|---|
| Code | `/opt/veyon/chat-application` (read-only for the app) |
| Settings | `backend/.env` (root + veyon only) |
| Uploaded files | `/var/lib/veyon/storage` |
| Database backups | `/var/backups/veyon` (daily, newest 7 kept) |
| Nginx site | `/etc/nginx/sites-available/veyon` (from `deploy/nginx/ubuntu-site.conf.template`) |
| systemd | `/etc/systemd/system/veyon-api@.service`, `veyon.target` |
| Remembered setup options | `/etc/veyon/deploy.env` |

Only Nginx is reachable from outside. The API workers, Redis and PostgreSQL
listen on 127.0.0.1 only.
