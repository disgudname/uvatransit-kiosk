#!/bin/bash
# Kiosk xinitrc: launches matchbox + Chromium pointed at the arrivals dashboard,
# falling back to a "not connected" page (showing this Pi's WiFi MAC address, for
# allowlisting on the wahoo network) until the network comes up, or a "not
# registered" page if it's online but the dashboard has no site assigned to this
# device's MAC yet. Runs as the X client under `startx` - see kiosk.service.
#
# Shows a branded "starting up" loading page immediately (the 03-splash stage's
# Plymouth theme covers the kernel-boot phase before this script even runs, but
# quits at the normal systemd handoff point - this page covers the gap from
# there until the first check-in result is known, so there's never a plain
# black screen at any point in the boot sequence).

set -u

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
CHANNEL_FILE="/tmp/kiosk-channel"
WLAN_IFACE="wlan0"
CHECK_INTERVAL=15

xset s off
xset s noblank
xset -dpms
unclutter --timeout 1 --jitter 5 --ignore-scrolling &
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
# site assigned yet - a normal, successful response, not a failure), and
# CHECKIN_DISPLAY_URL (a full URL override for non-bus-stop kiosks, e.g. a
# training-office display showing a spreadsheet instead of arrivals - empty for
# the common case). Also drops the dashboard-assigned update channel
# (dev/prod) into CHANNEL_FILE on every successful poll, for
# kiosk-self-update.sh to read - piggybacking on this existing poll instead of
# a second independent check-in call. Left untouched (not cleared) on a failed
# poll, so self-update keeps using the last known-good channel while offline.
CHECKIN_OK=0
CHECKIN_SITE_CODE=""
CHECKIN_DISPLAY_URL=""
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
    jq -r '.channel // "prod"' <<< "$response" > "$CHANNEL_FILE"
  else
    CHECKIN_OK=0
    CHECKIN_SITE_CODE=""
    CHECKIN_DISPLAY_URL=""
  fi
}

# Decides what Chromium should be pointed at right now, in priority order: a
# full URL override from the dashboard (non-bus-stop kiosks), the arrivals
# dashboard for the site code the dashboard assigned, the local site-code.txt
# fallback if the dashboard hasn't assigned anything, the "not registered" page
# (online, but nothing assigned at all), or the "not connected" page (the
# check-in request itself couldn't reach the dashboard).
want_target() {
  checkin
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

# chrome://gpu confirmed GPU rasterization/compositing are already hardware
# accelerated by default on this build (Debian's packaged Chromium already
# passes --enable-gpu-rasterization/--use-angle=gles itself) - no override
# needed there. The last line instead disables Site Isolation: it spawns a
# separate renderer process per origin as a defense against cross-site data
# leaks, which costs real memory for no benefit on a kiosk that only ever
# shows one fixed, trusted, same-origin page with no user-driven navigation.
CHROMIUM_FLAGS="--kiosk --incognito --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --disable-translate --no-first-run \
  --check-for-update-interval=31536000 --overscroll-history-navigation=0 \
  --autoplay-policy=no-user-gesture-required --window-position=0,0 \
  --disable-features=IsolateOrigins,site-per-process"

CURRENT_TARGET=""
CHROMIUM_PID=""

launch_chromium() {
  local target="$1"
  chromium $CHROMIUM_FLAGS "$target" &
  CHROMIUM_PID=$!
  CURRENT_TARGET="$target"
}

# Show the loading page immediately, so there's something branded on screen
# the moment X starts rather than a blank window while the grace period below
# runs.
launch_chromium "file://${LOADING_PAGE}"

# Initial grace period for WiFi/cellular to associate, so a normal boot doesn't
# flash the fallback page before settling on the real dashboard.
for _ in 1 2 3 4 5 6 7 8 9; do
  checkin
  [ "$CHECKIN_OK" = "1" ] && break
  sleep 5
done

WANT_TARGET="$(want_target)"
kill "$CHROMIUM_PID" 2>/dev/null
wait "$CHROMIUM_PID" 2>/dev/null
launch_chromium "$WANT_TARGET"

# Watchdog: restart Chromium if it dies, and flip between the dashboard, the
# not-connected page, and the not-registered page as check-in results change -
# no reboot required either way.
while true; do
  sleep "$CHECK_INTERVAL"

  WANT_TARGET="$(want_target)"

  if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
    launch_chromium "$WANT_TARGET"
  elif [ "$WANT_TARGET" != "$CURRENT_TARGET" ]; then
    kill "$CHROMIUM_PID" 2>/dev/null
    wait "$CHROMIUM_PID" 2>/dev/null
    launch_chromium "$WANT_TARGET"
  fi
done
