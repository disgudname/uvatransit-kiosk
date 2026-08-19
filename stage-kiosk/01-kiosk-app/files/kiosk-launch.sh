#!/bin/bash
# Kiosk xinitrc: launches matchbox + a single, persistent Chromium instance
# showing loading.html, which hosts a full-viewport <iframe> that this
# script redirects by writing STATUS_FILE (polled by loading.html's JS over
# HTTP via kiosk-status-server.py - Chromium's fetch() doesn't support
# file:// and XHR-to-file:// needs a flag whose behavior isn't worth
# depending on). loading.html keeps its own splash opaque over the iframe
# until the new content has actually finished loading, so there is never a
# black-root/white-Chromium-relaunch flash on screen when the target
# changes - previously this script killed and relaunched Chromium itself
# for every change, which is exactly what caused that. Runs as the X client
# under `startx` - see kiosk.service.
#
# The 03-splash stage's Plymouth theme covers the kernel-boot phase before
# this script even runs, quitting at the normal systemd handoff point;
# loading.html's overlay covers everything from there on, including the
# entire process of figuring out what to actually show.

set -u

# Goes through logger, not plain echo - startx doesn't route this script's
# own stdout to kiosk.service's journal the way it does a child process's
# stderr (confirmed live: unclutter's usage-error output showed up in
# `journalctl -u kiosk.service`, this function's echo output never did),
# and logger sidesteps that entirely by opening its own connection to the
# journal instead of relying on inherited file descriptors.
log() { logger -t kiosk-launch "$*"; }

BASE_URL="https://utsopsdashboard.com/arrivalsdisplay"
CHECKIN_ENDPOINT="https://utsopsdashboard.com/v1/kiosk-checkin"
SITE_CODE_FILE="/boot/firmware/site-code.txt"
RUSTDESK_ID_FILE="/boot/firmware/rustdesk-id.txt"
IMAGE_BUILD_FILE="/etc/kiosk/image-build.txt"
FALLBACK_TEMPLATE="/etc/kiosk/mac-fallback.html"
FALLBACK_RENDERED="/tmp/kiosk-mac-fallback.html"
NOT_REGISTERED_TEMPLATE="/etc/kiosk/not-registered.html"
NOT_REGISTERED_RENDERED="/tmp/kiosk-not-registered.html"
LOADING_PAGE="/etc/kiosk/loading.html"
STATUS_FILE="/tmp/kiosk-status.json"
WLAN_IFACE="wlan0"
CHECK_INTERVAL=15

xset s off
xset s noblank
xset -dpms
unclutter -idle 1 -jitter 5 &
matchbox-window-manager -use_cursor no &

get_mac() {
  if [ -f "/sys/class/net/${WLAN_IFACE}/address" ]; then
    cat "/sys/class/net/${WLAN_IFACE}/address"
  else
    echo "unknown"
  fi
}

read_trimmed() {
  [ -f "$1" ] && tr -d '[:space:]' < "$1" || true
}

dashboard_url() {
  echo "${BASE_URL}?code=$1"
}

render_page() {
  sed -e "s/{{MAC}}/$(get_mac)/g" -e "s/{{HOSTNAME}}/$(hostname)/g" "$1" > "$2"
}

# Checks in with the dashboard, reporting this device's identity and getting
# back whatever it's been assigned. Sets CHECKIN_OK (whether the request itself
# succeeded - i.e. is there a network at all), CHECKIN_SITE_CODE (empty if no
# site assigned yet - a normal, successful response, not a failure),
# CHECKIN_DISPLAY_URL (a full URL override for non-bus-stop kiosks, e.g. a
# training-office display showing a spreadsheet instead of arrivals - empty
# for the common case), and CHECKIN_CHANNEL (dev/prod - published via
# STATUS_FILE below for kiosk-self-update.sh to read over the same local
# HTTP endpoint, no separate check-in call needed).
CHECKIN_OK=0
CHECKIN_SITE_CODE=""
CHECKIN_DISPLAY_URL=""
CHECKIN_CHANNEL="prod"
checkin() {
  local payload response
  payload="$(jq -n \
    --arg mac "$(get_mac)" \
    --arg hostname "$(hostname)" \
    --arg rustdesk_id "$(read_trimmed "$RUSTDESK_ID_FILE")" \
    --arg image_build "$(read_trimmed "$IMAGE_BUILD_FILE")" \
    '{mac: $mac, hostname: $hostname, rustdesk_id: $rustdesk_id, image_build: $image_build}')"
  if response="$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
    -d "$payload" "$CHECKIN_ENDPOINT")"; then
    CHECKIN_OK=1
    CHECKIN_SITE_CODE="$(jq -r '.site_code // empty' <<< "$response")"
    CHECKIN_DISPLAY_URL="$(jq -r '.url // empty' <<< "$response")"
    CHECKIN_CHANNEL="$(jq -r '.channel // "prod"' <<< "$response")"
  else
    CHECKIN_OK=0
    CHECKIN_SITE_CODE=""
    CHECKIN_DISPLAY_URL=""
  fi
}

# Decides what should be showing right now, in priority order: a full URL
# override from the dashboard (non-bus-stop kiosks), the arrivals dashboard
# for the site code the dashboard assigned, the local site-code.txt fallback
# if the dashboard hasn't assigned anything, the "not registered" page
# (online, but nothing assigned at all), or the "not connected" page (the
# check-in request itself couldn't reach the dashboard). Reads whatever
# checkin() last set rather than calling it itself - every caller captures
# this function's output via `$(...)`, which forks a subshell, and a
# checkin() called from inside that subshell would set CHECKIN_CHANNEL in a
# copy of the shell state that's discarded the instant the subshell exits.
# CHECKIN_SITE_CODE/CHECKIN_DISPLAY_URL never showed the bug because they're
# only read right here, inside that same subshell, before it exits -
# CHECKIN_CHANNEL is read later by write_status() back in the parent shell,
# where it would otherwise stay frozen at whatever it was at boot forever.
decide_target() {
  if [ "$CHECKIN_OK" != "1" ]; then
    render_page "$FALLBACK_TEMPLATE" "$FALLBACK_RENDERED"
    echo "file://${FALLBACK_RENDERED}"
    return
  fi
  if [ -n "$CHECKIN_DISPLAY_URL" ]; then
    echo "$CHECKIN_DISPLAY_URL"
    return
  fi
  if [ -n "$CHECKIN_SITE_CODE" ]; then
    dashboard_url "$CHECKIN_SITE_CODE"
    return
  fi
  local local_code
  local_code="$(read_trimmed "$SITE_CODE_FILE")"
  if [ -n "$local_code" ]; then
    dashboard_url "$local_code"
    return
  fi
  render_page "$NOT_REGISTERED_TEMPLATE" "$NOT_REGISTERED_RENDERED"
  echo "file://${NOT_REGISTERED_RENDERED}"
}

# Publishes the current decision for loading.html to pick up. Atomic
# write (tmp + rename) so kiosk-status-server.py never serves a
# half-written file mid-update.
write_status() {
  jq -n --arg target "$1" --arg channel "$CHECKIN_CHANNEL" \
    '{target: $target, channel: $channel}' > "${STATUS_FILE}.tmp"
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# chrome://gpu confirmed GPU rasterization/compositing are already hardware
# accelerated by default on this build (Debian's packaged Chromium already
# passes --enable-gpu-rasterization/--use-angle=gles itself) - no override
# needed there. The last line instead disables Site Isolation: it spawns a
# separate renderer process per origin as a defense against cross-site data
# leaks, which costs real memory for no benefit on a kiosk that only ever
# shows content inside one fixed, trusted top-level shell page.
CHROMIUM_FLAGS="--kiosk --incognito --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --disable-translate --no-first-run \
  --check-for-update-interval=31536000 --overscroll-history-navigation=0 \
  --autoplay-policy=no-user-gesture-required --window-position=0,0 \
  --disable-features=IsolateOrigins,site-per-process"

CHROMIUM_PID=""

launch_chromium() {
  log "launching chromium"
  chromium $CHROMIUM_FLAGS "file://${LOADING_PAGE}" &
  CHROMIUM_PID=$!
  log "chromium launched, pid=$CHROMIUM_PID"
}

# Chromium launches exactly once, always at loading.html - its own JS then
# decides what's actually on screen via STATUS_FILE. From here this script's
# only job is keeping STATUS_FILE current and relaunching Chromium if it
# dies outright (crash recovery, not a target change).
log "kiosk-launch.sh starting"
launch_chromium

# Initial grace period for WiFi/cellular to associate, so a normal boot
# doesn't briefly surface the "not connected" fallback before settling on
# the real dashboard. loading.html's splash covers this whole wait either
# way (STATUS_FILE doesn't exist yet, so the overlay just stays up), so
# there's no real cost to waiting the full period out here.
for _ in 1 2 3 4 5 6 7 8 9; do
  checkin
  [ "$CHECKIN_OK" = "1" ] && break
  sleep 5
done

FIRST_TARGET="$(decide_target)"
log "initial target: $FIRST_TARGET"
write_status "$FIRST_TARGET"

# Watchdog: keep STATUS_FILE current, and restart Chromium if it dies.
while true; do
  sleep "$CHECK_INTERVAL"
  checkin
  TARGET="$(decide_target)"
  write_status "$TARGET"
  if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
    log "chromium (pid $CHROMIUM_PID) is not running, relaunching"
    launch_chromium
  fi
done
