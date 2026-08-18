#!/bin/bash
# Pulls the latest kiosk app files (kiosk-launch.sh + fallback/loading pages)
# from the public uvatransit-kiosk repo, on whichever branch matches this
# device's dashboard-assigned channel (dev/prod - see kiosk-launch.sh's
# checkin(), which writes CHANNEL_FILE on every poll), and restarts
# kiosk.service if anything changed. Run periodically by
# kiosk-self-update.timer.
#
# Deliberately scoped to just the app layer: services, sysctls, WiFi config,
# RustDesk provisioning, and the Plymouth theme are build-time-only and still
# need a reflash to change. Those rarely change and hot-patching root-owned
# system config remotely is a much bigger risk than swapping out the
# Chromium-launching shell script and the HTML pages it shows.

set -u

REPO_DIR="/opt/uvatransit-kiosk"
REPO_URL="https://github.com/disgudname/uvatransit-kiosk.git"
CHANNEL_FILE="/tmp/kiosk-channel"
DEFAULT_CHANNEL="prod"
APP_VERSION_FILE="/etc/kiosk/app-version.txt"

log() { echo "[kiosk-self-update] $*"; }

CHANNEL="$(tr -d '[:space:]' < "$CHANNEL_FILE" 2>/dev/null || true)"
case "$CHANNEL" in
  dev|prod) ;;
  *) CHANNEL="$DEFAULT_CHANNEL" ;;
esac

if [ ! -d "$REPO_DIR/.git" ]; then
  log "no local checkout yet, cloning branch '$CHANNEL'"
  rm -rf "$REPO_DIR"
  if ! git clone --depth 1 --branch "$CHANNEL" "$REPO_URL" "$REPO_DIR"; then
    log "clone failed (offline, or branch '$CHANNEL' doesn't exist yet) - will retry next run"
    exit 0
  fi
fi

if ! git -C "$REPO_DIR" fetch --depth 1 origin "$CHANNEL"; then
  log "fetch failed (offline, or branch '$CHANNEL' doesn't exist), skipping this run"
  exit 0
fi

NEW_SHA="$(git -C "$REPO_DIR" rev-parse FETCH_HEAD)"
OLD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")"

if [ "$NEW_SHA" = "$OLD_SHA" ]; then
  exit 0
fi

log "channel=$CHANNEL updating $OLD_SHA -> $NEW_SHA"
git -C "$REPO_DIR" reset --hard FETCH_HEAD

SRC="$REPO_DIR/stage-kiosk/01-kiosk-app/files"
install -v -m 755 -o root -g root "$SRC/kiosk-launch.sh" /etc/kiosk/kiosk-launch.sh
install -v -m 644 -o root -g root "$SRC/mac-fallback.html" /etc/kiosk/mac-fallback.html
install -v -m 644 -o root -g root "$SRC/not-registered.html" /etc/kiosk/not-registered.html
install -v -m 644 -o root -g root "$SRC/loading.html" /etc/kiosk/loading.html

echo "$NEW_SHA" > "$APP_VERSION_FILE"

log "restarting kiosk.service"
systemctl restart kiosk.service
