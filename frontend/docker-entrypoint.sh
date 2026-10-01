#!/bin/sh
# Runs before nginx starts (nginx image's /docker-entrypoint.d hook).
set -e

HTML=/usr/share/nginx/html

# 1. Point the app at the backend from environment variables, so one image
#    works anywhere. Unset -> the config.js baked into the image is kept.
if [ -n "${API_BASE}${API_HTTP_PORT}${API_HTTPS_PORT}" ]; then
  cat > "$HTML/config.js" <<EOF
// Generated at container start from API_BASE / API_HTTP_PORT / API_HTTPS_PORT.
window.APP_CONFIG = {
  apiBase: '${API_BASE:-}',
  apiHttpPort: ${API_HTTP_PORT:-4000},
  apiHttpsPort: ${API_HTTPS_PORT:-4443},
};
EOF
  echo "chat-frontend: config.js -> apiBase='${API_BASE:-}' http=${API_HTTP_PORT:-4000} https=${API_HTTPS_PORT:-4443}"
fi

# 2. HTTPS (needed for phones on the LAN — WebCrypto only runs on https or
#    localhost) when a cert pair is mounted at /etc/nginx/certs.
if [ -f /etc/nginx/certs/cert.pem ] && [ -f /etc/nginx/certs/key.pem ]; then
  cat > /etc/nginx/conf.d/ssl.conf <<'EOF'
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    root /usr/share/nginx/html;
    include /etc/nginx/snippets/app.conf;
}
EOF
  echo "chat-frontend: HTTPS enabled on 443"
else
  rm -f /etc/nginx/conf.d/ssl.conf
  echo "chat-frontend: no certs at /etc/nginx/certs — HTTP only"
fi
