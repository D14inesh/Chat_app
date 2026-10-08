#!/usr/bin/env bash
# Update Veyon Chat on Ubuntu to the latest code on GitHub:
#
#   cd /opt/veyon/chat-application && sudo bash deploy/ubuntu/update.sh
#
# Pulls, then re-runs setup.sh with the remembered options: new packages,
# new database tables, new website version, and the API workers restarted
# one at a time (the others keep serving, so nobody is cut off).
set -euo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash deploy/ubuntu/update.sh" >&2; exit 1; }
cd "$APP"
echo "== Latest code"
# The repo folder is owned by whoever cloned it; let root's git work in it.
SAFE=$(git config --global --get-all safe.directory || true)
[[ $'\n'"$SAFE"$'\n' == *$'\n'"$APP"$'\n'* ]] || git config --global --add safe.directory "$APP"
git pull --ff-only
exec bash "$APP/deploy/ubuntu/setup.sh" "$@"
