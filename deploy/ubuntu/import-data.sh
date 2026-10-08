#!/usr/bin/env bash
# Move the data from the Windows server to this Ubuntu server (run setup.sh first):
#
#   sudo bash deploy/ubuntu/import-data.sh --dump /tmp/move/vesper_chat-20261008-020000.dump \
#        --storage /tmp/move/storage --env /tmp/move/windows.env
#
#   --dump FILE     a backup from the Windows server's database\backups folder
#                   (made daily; pg_dump custom format). REPLACES this server's database.
#   --storage DIR   the Windows server's storage folder (uploads, avatars, wallpapers, ...)
#   --env FILE      the Windows server's backend\.env: its JWT_SECRET (everyone stays
#                   signed in), VAPID keys (push notifications keep working) and Gmail
#                   settings are copied. Database/Redis/address settings here are kept.
#   --yes           don't ask before replacing the database
set -euo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$APP/backend/.env"
DATA=/var/lib/veyon/storage
DUMP="" STORAGE="" OLD_ENV="" YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dump) DUMP="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --env) OLD_ENV="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "run deploy/ubuntu/setup.sh first" >&2; exit 1; }
[ -n "$DUMP$STORAGE$OLD_ENV" ] || { sed -n '2,15p' "$0"; exit 1; }
[ -z "$DUMP" ] || [ -f "$DUMP" ] || { echo "no such file: $DUMP" >&2; exit 1; }
[ -z "$STORAGE" ] || [ -d "$STORAGE" ] || { echo "no such folder: $STORAGE" >&2; exit 1; }
[ -z "$OLD_ENV" ] || [ -f "$OLD_ENV" ] || { echo "no such file: $OLD_ENV" >&2; exit 1; }
PGDB=$(sed -n 's/^PGDATABASE=//p' "$ENV_FILE" | tail -1); PGDB=${PGDB:-vesper_chat}

if [ -n "$DUMP" ] && [ "$YES" != 1 ]; then
    read -r -p "This REPLACES everything in database '$PGDB' on this server. Type yes to go on: " a
    [ "$a" = yes ] || { echo "stopped"; exit 1; }
fi

echo "== Stopping the API workers"
systemctl stop veyon.target 'veyon-api@*'

if [ -n "$OLD_ENV" ]; then
    echo "== Keys from the old .env"
    python3 - "$OLD_ENV" "$ENV_FILE" <<'PY'
import re, sys
old, new = sys.argv[1:3]
keys = ["JWT_SECRET", "VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY", "VAPID_SUBJECT", "SMTP_HOST", "SMTP_PORT",
        "SMTP_USER", "SMTP_PASS", "MAIL_FROM", "TENOR_API_KEY", "SESSION_TTL", "MAX_UPLOAD_BYTES"]
src = {}
for line in open(old, encoding="utf-8-sig").read().splitlines():
    m = re.match(r"^\s*([A-Z_]+)\s*=(.*)$", line)
    if m and m.group(1) in keys and m.group(2).strip():
        src[m.group(1)] = m.group(2).strip()
text = open(new, encoding="utf-8").read()
for k, v in src.items():
    pat = re.compile(rf"^{k}=.*$", re.M)
    text = pat.sub(lambda _: f"{k}={v}", text) if pat.search(text) else text.rstrip("\n") + f"\n{k}={v}\n"
open(new, "w", encoding="utf-8").write(text)
print("  copied:", ", ".join(sorted(src)) or "nothing")
PY
fi

if [ -n "$DUMP" ]; then
    echo "== Database '$PGDB' from $(basename "$DUMP")"
    # Fresh, empty database owned by veyon, then the backup into it. Read
    # through stdin so the postgres user needn't have access to the file.
    sudo -u postgres psql -qtA -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$PGDB\" WITH (FORCE)" \
        -c "CREATE DATABASE \"$PGDB\" OWNER veyon"
    sudo -u postgres psql -qtA -d "$PGDB" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" >/dev/null
    set +e
    sudo -u postgres pg_restore --no-owner --no-acl --role=veyon -d "$PGDB" < "$DUMP" 2>/tmp/veyon-restore.log
    rc=$?
    set -e
    # "extension already exists" is expected and harmless; anything else isn't.
    real=$(grep -E "error:" /tmp/veyon-restore.log | grep -vi "pgcrypto" || true)
    if [ $rc -ne 0 ] && [ -n "$real" ]; then
        echo "$real" | head -20
        echo "Restore had errors (full log: /tmp/veyon-restore.log). Workers left stopped." >&2
        exit 1
    fi
    sudo -u postgres psql -qtA -d "$PGDB" -c "SELECT '  users: ' || count(*) FROM users" \
        -c "SELECT '  messages: ' || count(*) FROM messages"
fi

if [ -n "$STORAGE" ]; then
    echo "== Uploaded files"
    for sub in uploads avatars wallpapers chat_backups catalog; do
        if [ -d "$STORAGE/$sub" ]; then
            install -d -m 750 -o veyon -g veyon "$DATA/$sub"
            cp -a "$STORAGE/$sub/." "$DATA/$sub/"
            echo "  $sub: $(find "$DATA/$sub" -type f | wc -l) files"
        fi
    done
    chown -R veyon:veyon "$DATA"
    # Files from Windows arrive marked executable: plain data, service user only.
    find "$DATA" -type d -exec chmod 750 {} +
    find "$DATA" -type f -exec chmod 640 {} +
fi

echo "== Starting the API workers (schema updates apply on start)"
systemctl start veyon.target
for p in $(systemctl list-units --plain --no-legend --all 'veyon-api@*' | awk '{print $1}' | sed 's/veyon-api@//; s/\.service//'); do
    systemctl start "veyon-api@$p"
    for _ in $(seq 60); do curl -fs "http://127.0.0.1:$p/api/health" >/dev/null && break; sleep 0.5; done
    curl -fs "http://127.0.0.1:$p/api/health" >/dev/null && echo "  veyon-api@$p up" || echo "  veyon-api@$p NOT up — journalctl -u veyon-api@$p -n 50"
done
echo "Done."
