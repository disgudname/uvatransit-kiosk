#!/bin/bash
# Kiosk xinitrc: launches matchbox + Chromium pointed at the arrivals dashboard,
# falling back to a "not connected" page (showing this Pi's WiFi MAC address, for
# allowlisting on the wahoo network) until the network comes up. Runs as the X
# client under `startx` - see kiosk.service.

set -u

BASE_URL="https://utsopsdashboard.com/arrivalsdisplay"
SITE_CODE_FILE="/boot/firmware/site-code.txt"
FALLBACK_TEMPLATE="/etc/kiosk/mac-fallback.html"
FALLBACK_RENDERED="/run/kiosk-mac-fallback.html"
WLAN_IFACE="wlan0"
CHECK_INTERVAL=15
CONNECT_CHECK_HOST="utsopsdashboard.com"

xset s off
xset s noblank
xset -dpms
unclutter --timeout 1 --jitter 5 --ignore-scrolling &
matchbox-window-manager -use_cursor no &

dashboard_url() {
  local code=""
  if [ -f "$SITE_CODE_FILE" ]; then
    code="$(tr -d '[:space:]' < "$SITE_CODE_FILE")"
  fi
  if [ -n "$code" ]; then
    echo "${BASE_URL}?code=${code}"
  else
    echo "${BASE_URL}"
  fi
}

render_fallback_page() {
  local mac="unknown"
  if [ -f "/sys/class/net/${WLAN_IFACE}/address" ]; then
    mac="$(cat "/sys/class/net/${WLAN_IFACE}/address")"
  fi
  sed -e "s/{{MAC}}/${mac}/g" -e "s/{{HOSTNAME}}/$(hostname)/g" \
    "$FALLBACK_TEMPLATE" > "$FALLBACK_RENDERED"
}

is_online() {
  curl -fsS --max-time 5 -o /dev/null "https://${CONNECT_CHECK_HOST}/"
}

CHROMIUM_FLAGS="--kiosk --incognito --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --disable-translate --no-first-run \
  --check-for-update-interval=31536000 --overscroll-history-navigation=0 \
  --autoplay-policy=no-user-gesture-required --window-position=0,0"

CURRENT_TARGET=""
CHROMIUM_PID=""

launch_chromium() {
  local target="$1"
  chromium $CHROMIUM_FLAGS "$target" &
  CHROMIUM_PID=$!
  CURRENT_TARGET="$target"
}

# Initial grace period for WiFi/cellular to associate, so a normal boot doesn't
# flash the fallback page before settling on the real dashboard.
for _ in 1 2 3 4 5 6 7 8 9; do
  is_online && break
  sleep 5
done

if is_online; then
  launch_chromium "$(dashboard_url)"
else
  render_fallback_page
  launch_chromium "file://${FALLBACK_RENDERED}"
fi

# Watchdog: restart Chromium if it dies, and flip between the dashboard and the
# fallback page as connectivity changes - no reboot required either way.
while true; do
  sleep "$CHECK_INTERVAL"

  if is_online; then
    WANT_TARGET="$(dashboard_url)"
  else
    render_fallback_page
    WANT_TARGET="file://${FALLBACK_RENDERED}"
  fi

  if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
    launch_chromium "$WANT_TARGET"
  elif [ "$WANT_TARGET" != "$CURRENT_TARGET" ]; then
    kill "$CHROMIUM_PID" 2>/dev/null
    wait "$CHROMIUM_PID" 2>/dev/null
    launch_chromium "$WANT_TARGET"
  fi
done
