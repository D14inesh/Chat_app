#!/usr/bin/env bash
# Veyon Chat on Ubuntu (22.04 / 24.04 / 26.04):
#
#   Users ──► Nginx (HTTPS) ──► API workers (FastAPI + WebSocket, systemd)
#                                   ──► Redis (live state) / PostgreSQL (data)
#
# Run from the cloned repo, as root, e.g. with the code in /opt/veyon:
#
#   sudo git clone https://github.com/<you>/chat-application.git /opt/veyon/chat-application
#   cd /opt/veyon/chat-application
#   sudo bash deploy/ubuntu/setup.sh --domain chat.example.com --email you@example.com
#   sudo bash deploy/ubuntu/setup.sh --ip 203.0.113.10            # no domain: self-signed HTTPS
#
# Safe to re-run (it keeps passwords, keys and data); deploy/ubuntu/update.sh
# re-runs it after a git pull. Options are remembered in /etc/veyon/deploy.env.
#
#   --domain NAME     public name → free trusted HTTPS from Let's Encrypt (needs
#                     the name pointing at this server and port 80 reachable)
#   --email ADDR      for Let's Encrypt expiry notices (with --domain)
#   --ip ADDR         no domain: self-signed certificate for this IP (browsers warn)
#   --workers N       API worker processes (default: CPU cores, 2..8)
#   --https-port P    website + API (default 443)
#   --http-port P     redirects to HTTPS + Let's Encrypt checks (default 80)
#   --app-port P      extra HTTPS port with the API only, for the phone app
#                     (default 4843 = what the current APK uses; 0 = off)
#   --worker-port P   first worker port on 127.0.0.1 (default 4810)
set -euo pipefail
# (Never `cmd | grep -q` here: with pipefail, grep quitting early can make the
# pipe fail at random. Capture the output first, then test it.)

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$APP/deploy"
CONF_DIR=/etc/veyon
SAVED="$CONF_DIR/deploy.env"
DATA=/var/lib/veyon
BACKUPS=/var/backups/veyon
# Generated website files (config.js, version.json): Nginx must read them,
# so not under $DATA (private to the service user).
SITE=/var/www/veyon
ENV_FILE="$APP/backend/.env"

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash deploy/ubuntu/setup.sh ..."
[ -f "$APP/backend/run.py" ] || die "run this from the chat-application repo (backend/run.py not found)"

# ── Options (command line > remembered > defaults) ───────────────────
DOMAIN="" EMAIL="" IP="" WORKERS="" HTTPS_PORT="" HTTP_PORT="" APP_PORT="" WORKER_PORT=""
[ -f "$SAVED" ] && . "$SAVED"
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --ip) IP="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --https-port) HTTPS_PORT="$2"; shift 2 ;;
        --http-port) HTTP_PORT="$2"; shift 2 ;;
        --app-port) APP_PORT="$2"; shift 2 ;;
        --worker-port) WORKER_PORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done
if [ -z "$WORKERS" ]; then
    WORKERS=$(nproc); [ "$WORKERS" -lt 2 ] && WORKERS=2; [ "$WORKERS" -gt 8 ] && WORKERS=8
fi
HTTPS_PORT=${HTTPS_PORT:-443}; HTTP_PORT=${HTTP_PORT:-80}; APP_PORT=${APP_PORT:-4843}; WORKER_PORT=${WORKER_PORT:-4810}
if [ -z "$DOMAIN" ] && [ -z "$IP" ]; then
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    warn "no --domain or --ip given: using this machine's address $IP (self-signed HTTPS)"
fi
[ -n "$DOMAIN" ] && [ -z "$EMAIL" ] && die "--domain needs --email (Let's Encrypt sends expiry notices there)"
NAME=${DOMAIN:-$IP}
SUFFIX=""; [ "$HTTPS_PORT" != 443 ] && SUFFIX=":$HTTPS_PORT"
ORIGIN="https://$NAME$SUFFIX"
WORKER_PORTS=$(seq "$WORKER_PORT" $((WORKER_PORT + WORKERS - 1)) | xargs)

step "Settings"
echo "  app folder:   $APP"
if [ -n "$DOMAIN" ]; then HOW="Let's Encrypt"; else HOW="self-signed"; fi
echo "  address:      $ORIGIN   ($HOW)"
if [ "$APP_PORT" = 0 ]; then echo "  phone app:    uses $ORIGIN"; else echo "  phone app:    https://$NAME:$APP_PORT (API only)"; fi
echo "  workers:      $WORKERS on 127.0.0.1: $WORKER_PORTS"

# ── Packages ─────────────────────────────────────────────────────────
step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx postgresql python3 python3-venv python3-dev build-essential \
    openssl ca-certificates curl git >/dev/null
# Redis (Ubuntu may ship Valkey, the drop-in open-source Redis, instead).
if apt-cache show redis-server >/dev/null 2>&1; then
    apt-get install -y -qq redis-server >/dev/null
else
    apt-get install -y -qq valkey-server >/dev/null
fi
[ -n "$DOMAIN" ] && apt-get install -y -qq certbot >/dev/null
if systemctl cat redis-server.service >/dev/null 2>&1; then
    REDIS_SERVICE=redis-server; REDIS_CONF=/etc/redis/redis.conf
else
    REDIS_SERVICE=valkey-server; REDIS_CONF=/etc/valkey/valkey.conf
fi
ok "nginx $(nginx -v 2>&1 | sed 's/.*\///'), $(psql --version | awk '{print "PostgreSQL",$3}'), $REDIS_SERVICE, $(python3 --version)"

# ── User and folders ─────────────────────────────────────────────────
step "User and folders"
id veyon >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin veyon
install -d -m 750 -o veyon -g veyon "$DATA" "$DATA/storage" "$BACKUPS"
install -d -m 755 -o root -g root "$SITE" "$CONF_DIR" /var/www/letsencrypt
for sub in uploads avatars wallpapers chat_backups catalog; do install -d -m 750 -o veyon -g veyon "$DATA/storage/$sub"; done
# Nginx (www-data) serves the website straight from the repo: every folder
# on the way must be enterable.
if ! sudo -u www-data test -r "$APP/frontend/public/index.html"; then
    die "Nginx can't read $APP/frontend/public — put the repo under /opt (e.g. /opt/veyon/chat-application), not a private home folder"
fi
ok "service user 'veyon', data in $DATA, backups in $BACKUPS"

# ── Python ───────────────────────────────────────────────────────────
step "Python packages"
[ -x "$APP/backend/venv/bin/python" ] || python3 -m venv "$APP/backend/venv"
"$APP/backend/venv/bin/pip" install -q --upgrade pip
"$APP/backend/venv/bin/pip" install -q -r "$APP/backend/requirements.txt"
ok "installed into backend/venv"

# ── backend/.env ─────────────────────────────────────────────────────
step "backend/.env"
secret() { openssl rand -hex "${1:-24}"; }
getenv() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 || true; }
setenv() {  # setenv KEY VALUE — replace the line or add it
    python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1:4]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
line = f"{key}={value}"
pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
text = pat.sub(lambda _: line, text) if pat.search(text) else text.rstrip("\n") + ("\n" if text else "") + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
}
if [ ! -f "$ENV_FILE" ]; then
    cp "$APP/backend/.env.example" "$ENV_FILE"
    ok "created from .env.example — add SMTP_USER/SMTP_PASS (Gmail app password) and VAPID keys"
else
    ok "exists — keeping its keys, updating server settings"
fi
JWT=$(getenv JWT_SECRET)
if [ ${#JWT} -lt 32 ] || [ "$JWT" = "replace-me-with-a-long-random-string" ]; then setenv JWT_SECRET "$(secret 48)"; fi
PGPASS=$(getenv PGPASSWORD)
[ "$(getenv PGUSER)" = "veyon" ] && [ -n "$PGPASS" ] || PGPASS=$(secret 24)
REDIS_PASS=$(getenv REDIS_URL | sed -n 's#^redis://:\([0-9a-f]*\)@.*#\1#p')
[ -n "$REDIS_PASS" ] || REDIS_PASS=$(secret 24)
PGDB=$(getenv PGDATABASE); PGDB=${PGDB:-vesper_chat}
setenv PGHOST 127.0.0.1
setenv PGPORT 5432
setenv PGUSER veyon
setenv PGPASSWORD "$PGPASS"
setenv PGDATABASE "$PGDB"
setenv REDIS_URL "redis://:$REDIS_PASS@127.0.0.1:6379/0"
setenv CORS_ORIGINS "$ORIGIN"
setenv COOKIE_SAMESITE lax
setenv SESSION_TTL 365d
setenv OTP_DEV_MODE 0
setenv PUBLIC_API_URL "$ORIGIN"
setenv STORAGE_DIR "$DATA/storage"
setenv BACKUP_DIR "$BACKUPS"
chown root:veyon "$ENV_FILE"; chmod 640 "$ENV_FILE"
ok "PostgreSQL user 'veyon', Redis password, CORS for $ORIGIN (file readable by root and veyon only)"

# ── PostgreSQL ───────────────────────────────────────────────────────
step "PostgreSQL"
systemctl enable --now postgresql >/dev/null
psql_admin() { sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA "$@"; }
if [ -z "$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname = 'veyon'")" ]; then
    psql_admin -c "CREATE ROLE veyon LOGIN PASSWORD '$PGPASS'"
else
    psql_admin -c "ALTER ROLE veyon PASSWORD '$PGPASS'"
fi
if [ -z "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '$PGDB'")" ]; then
    psql_admin -c "CREATE DATABASE \"$PGDB\" OWNER veyon"
fi
psql_admin -d "$PGDB" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto"
(cd "$APP/backend" && sudo -u veyon venv/bin/python setup_db.py >/dev/null)
ok "database '$PGDB' ready (schema applied)"

# ── Redis ────────────────────────────────────────────────────────────
step "Redis"
# Live state only (who's online, ringing calls, ...): memory only, this
# machine only. Our settings come last in the config, so they win.
BEFORE=$(cat "$CONF_DIR/redis.conf" "$REDIS_CONF" 2>/dev/null | sha256sum)
cat > "$CONF_DIR/redis.conf" <<EOF
# Veyon Chat — included at the end of $REDIS_CONF by deploy/ubuntu/setup.sh
bind 127.0.0.1 -::1
port 6379
protected-mode yes
requirepass $REDIS_PASS
save ""
appendonly no
maxmemory 256mb
maxmemory-policy noeviction
EOF
chmod 640 "$CONF_DIR/redis.conf"; chgrp "$(stat -c %G "$REDIS_CONF")" "$CONF_DIR/redis.conf"
grep -q "^include $CONF_DIR/redis.conf" "$REDIS_CONF" || echo "include $CONF_DIR/redis.conf" >> "$REDIS_CONF"
systemctl enable "$REDIS_SERVICE" >/dev/null 2>&1
# Restart only when the settings changed: a restart forgets the live state
# (who's online, ringing calls) and makes every worker reconnect.
if [ "$BEFORE" != "$(cat "$CONF_DIR/redis.conf" "$REDIS_CONF" | sha256sum)" ] || ! systemctl is-active -q "$REDIS_SERVICE"; then
    systemctl restart "$REDIS_SERVICE"
fi
if command -v redis-cli >/dev/null; then CLI=redis-cli; else CLI=valkey-cli; fi
PONG=""
for _ in $(seq 20); do
    PONG=$(REDISCLI_AUTH="$REDIS_PASS" $CLI -h 127.0.0.1 ping 2>/dev/null || true)
    [ "$PONG" = PONG ] && break; sleep 0.5
done
[ "$PONG" = PONG ] || die "Redis didn't start — journalctl -u $REDIS_SERVICE"
ok "$REDIS_SERVICE on 127.0.0.1:6379 (password protected)"

# ── HTTPS certificate ────────────────────────────────────────────────
step "HTTPS certificate"
SELF_DIR="$CONF_DIR/certs"
self_signed() {
    install -d -m 750 "$SELF_DIR"
    local have=""
    [ -f "$SELF_DIR/cert.pem" ] && have=$(openssl x509 -in "$SELF_DIR/cert.pem" -noout -ext subjectAltName 2>/dev/null || true)
    # Made once and kept: a new certificate means every browser warns again.
    if [[ "$have" != *"$NAME"* ]]; then
        local san="DNS:localhost,IP:127.0.0.1"
        if [[ "$NAME" =~ ^[0-9.]+$ ]]; then san="IP:$NAME,$san"; else san="DNS:$NAME,$san"; fi
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
            -addext "subjectAltName=$san" -keyout "$SELF_DIR/key.pem" -out "$SELF_DIR/cert.pem" 2>/dev/null
        chmod 640 "$SELF_DIR/key.pem"
    fi
}
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ -n "$DOMAIN" ] && [ -f "$LE_DIR/fullchain.pem" ]; then
    CERT="$LE_DIR/fullchain.pem"; KEY="$LE_DIR/privkey.pem"; HSTS=1
    ok "Let's Encrypt certificate for $DOMAIN (renews automatically)"
else
    # Domain without a certificate yet: start on a temporary self-signed
    # one, ask Let's Encrypt below, then switch.
    self_signed
    CERT="$SELF_DIR/cert.pem"; KEY="$SELF_DIR/key.pem"; HSTS=0
    [ -z "$DOMAIN" ] && ok "self-signed for $NAME (browsers show a warning once; a domain gets a trusted one)"
fi

# ── Nginx ────────────────────────────────────────────────────────────
write_nginx() {
    local ver h2l="" h2on="" app_server=""
    ver=$(nginx -v 2>&1 | sed 's/.*\///')
    if [ "$(printf '%s\n1.25.1\n' "$ver" | sort -V | head -1)" = "1.25.1" ]; then
        h2on="    http2        on;"$'\n'
    else
        h2l=" http2"
    fi
    if [ "$APP_PORT" != 0 ]; then
        app_server="
# ── API only, for the phone app (port $APP_PORT) ──────────────────────
server {
    listen       $APP_PORT ssl$h2l;
    listen       [::]:$APP_PORT ssl$h2l;
${h2on}    server_name  $NAME;
    include      veyon-tls.conf;
    client_max_body_size  110m;

    location / {
        proxy_pass  http://veyon_api;
        include     veyon-proxy.conf;
    }
}"
    fi
    python3 - "$DEPLOY/nginx/ubuntu-site.conf.template" /etc/nginx/sites-available/veyon <<PY
import sys
src, dst = sys.argv[1:3]
s = open(src, encoding="utf-8").read()
ups = "\n".join(f"    server 127.0.0.1:{p} max_fails=2 fail_timeout=3s;" for p in "$WORKER_PORTS".split())
for k, v in {"UPSTREAMS": ups, "HTTP_PORT": "$HTTP_PORT", "HTTPS_PORT": "$HTTPS_PORT", "SERVER_NAME": "$NAME",
             "HTTPS_SUFFIX": "$SUFFIX", "PUBLIC": "$APP/frontend/public", "H2_LISTEN": "$h2l",
             "H2_ON": """$h2on""", "APP_SERVER": """$app_server"""}.items():
    s = s.replace("{{" + k + "}}", v)
open(dst, "w", encoding="utf-8").write(s)
PY
    {
        echo "# Written by deploy/ubuntu/setup.sh"
        echo "ssl_certificate      $CERT;"
        echo "ssl_certificate_key  $KEY;"
        echo "ssl_protocols        TLSv1.2 TLSv1.3;"
        echo "ssl_session_cache    shared:VeyonSSL:10m;"
        echo "ssl_session_timeout  1h;"
        if [ "$HSTS" = 1 ]; then echo 'add_header Strict-Transport-Security "max-age=31536000" always;'; fi
    } > /etc/nginx/veyon-tls.conf
    sed "s#{{SITE}}#$SITE#" "$DEPLOY/nginx/veyon-site.conf.template" > /etc/nginx/veyon-site.conf
    cp "$DEPLOY/nginx/veyon-api.conf" "$DEPLOY/nginx/veyon-proxy.conf" /etc/nginx/
    ln -sf /etc/nginx/sites-available/veyon /etc/nginx/sites-enabled/veyon
    rm -f /etc/nginx/sites-enabled/default
}

step "Nginx"
# Room for many live sockets (each online user holds two connections).
sed -i -E 's/^(\s*)worker_connections\s+[0-9]+;/\1worker_connections 8192;/' /etc/nginx/nginx.conf
grep -q '^worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -i '/^worker_processes/a worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
# The website's own config (API on the same address) and version fingerprint.
printf "// Generated by deploy/ubuntu/setup.sh - the API is behind the same Nginx.\nwindow.APP_CONFIG = { apiBase: '', sameOrigin: true };\n" > "$SITE/config.js"
VERSION=$(cd "$APP/frontend/public" && find . -type f -printf '%P|%s|%T@\n' | sort | sha256sum | cut -c1-16)
printf '{"version":"%s"}\n' "$VERSION" > "$SITE/version.json"
write_nginx
nginx -t 2>&1 | sed 's/^/  /' || die "Nginx config check failed (see above)"
systemctl enable nginx >/dev/null 2>&1
systemctl reload-or-restart nginx
ok "website + API on $ORIGIN$([ "$APP_PORT" != 0 ] && echo ", phone-app API on :$APP_PORT")"

if [ -n "$DOMAIN" ] && [ "$HSTS" = 0 ]; then
    step "Let's Encrypt"
    if certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" --email "$EMAIL" \
            --agree-tos --non-interactive --keep-until-expiring; then
        CERT="$LE_DIR/fullchain.pem"; KEY="$LE_DIR/privkey.pem"; HSTS=1
        write_nginx; nginx -t >/dev/null 2>&1 && systemctl reload nginx
        install -d /etc/letsencrypt/renewal-hooks/deploy
        printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/veyon-nginx.sh
        chmod 755 /etc/letsencrypt/renewal-hooks/deploy/veyon-nginx.sh
        ok "trusted certificate for $DOMAIN; renews by itself (certbot.timer)"
    else
        warn "Let's Encrypt failed — still on the self-signed certificate. Check that $DOMAIN points to this"
        warn "server and port $HTTP_PORT is open, then re-run this script."
    fi
fi

# ── API workers (systemd) ────────────────────────────────────────────
step "API workers"
sed -e "s#{{APP}}#$APP#g" -e "s#{{REDIS_SERVICE}}#$REDIS_SERVICE#g" \
    "$DEPLOY/ubuntu/veyon-api@.service" > /etc/systemd/system/veyon-api@.service
cp "$DEPLOY/ubuntu/veyon.target" /etc/systemd/system/veyon.target
systemctl daemon-reload
systemctl enable veyon.target >/dev/null 2>&1
# Workers from an earlier run that are no longer wanted (fewer --workers).
for unit in $(systemctl list-units --plain --no-legend 'veyon-api@*' | awk '{print $1}'); do
    port=${unit#veyon-api@}; port=${port%.service}
    [[ " $WORKER_PORTS " == *" $port "* ]] || { systemctl disable --now "$unit" >/dev/null 2>&1; echo "  removed $unit"; }
done
health() { curl -fsS --max-time 3 "http://127.0.0.1:$1/api/health" >/dev/null 2>&1; }
for port in $WORKER_PORTS; do
    systemctl enable "veyon-api@$port" >/dev/null 2>&1
    # One at a time, waiting for each to answer: on an update, the others
    # keep serving while this one restarts.
    systemctl restart "veyon-api@$port"
    for _ in $(seq 60); do health "$port" && break; sleep 0.5; done
    health "$port" && ok "veyon-api@$port up" || die "veyon-api@$port didn't start — journalctl -u veyon-api@$port -n 50"
    # Nginx benches a worker it couldn't reach for fail_timeout (3 s): wait it
    # out, so this one is back in rotation before the next one restarts.
    if [ "$port" != "${WORKER_PORTS##* }" ]; then sleep 4; fi
done

# ── Firewall ─────────────────────────────────────────────────────────
if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    step "Firewall (ufw)"
    for p in "$HTTP_PORT" "$HTTPS_PORT" $([ "$APP_PORT" != 0 ] && echo "$APP_PORT"); do ufw allow "$p/tcp" >/dev/null; echo "  $p open"; done
fi

# ── Remember options, check ──────────────────────────────────────────
cat > "$SAVED" <<EOF
# deploy/ubuntu/setup.sh options — re-used by later runs and update.sh
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
IP="$IP"
WORKERS="$WORKERS"
HTTPS_PORT="$HTTPS_PORT"
HTTP_PORT="$HTTP_PORT"
APP_PORT="$APP_PORT"
WORKER_PORT="$WORKER_PORT"
EOF

step "Check"
H=$(curl -fsSk --max-time 5 --resolve "$NAME:$HTTPS_PORT:127.0.0.1" "https://$NAME:$HTTPS_PORT/api/health" || true)
echo "  $H"
[[ "$H" == *'"redis":"ok"'* ]] || die "health check through Nginx failed — journalctl -u 'veyon-api@*' -n 50"
cat <<EOF

$(printf '\033[1;32mDone.\033[0m')
  Website:     $ORIGIN
  Phone app:   $([ "$APP_PORT" != 0 ] && echo "https://$NAME:$APP_PORT" || echo "uses $ORIGIN")
  Logs:        journalctl -u 'veyon-api@*' -f      /var/log/nginx/
  Restart:     systemctl restart veyon.target
  Update:      sudo bash deploy/ubuntu/update.sh
EOF
