#!/bin/sh
# Container start-up: make sure there is a usable JWT_SECRET, then run the app.
# No secret configured -> generate one once and keep it in the storage volume,
# so sessions survive restarts and nobody has to edit a file by hand.
set -e

SECRET_FILE=/data/storage/.jwt_secret

if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "replace-me-with-a-long-random-string" ] || [ "${#JWT_SECRET}" -lt 32 ]; then
  if [ ! -s "$SECRET_FILE" ]; then
    python -c "import secrets; print(secrets.token_hex(48))" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "chat-backend: generated a new JWT_SECRET in $SECRET_FILE"
  fi
  JWT_SECRET=$(cat "$SECRET_FILE")
  export JWT_SECRET
fi

exec "$@"
