#!/bin/bash
# Kiosk xinitrc: launches matchbox + a single, persistent Chromium instance.
# Chromium launches once, pointed at loading.html (a plain splash, no
# iframe), and this script swaps what's actually on screen by opening the
# real target as a genuine top-level tab (via cdp-tab-swap.py's use of
# Chromium's CDP HTTP endpoints), waiting for it to finish loading, then
# activating it and closing whatever tab was showing before. This used to
# go through a full-viewport <iframe> inside loading.html instead - that
# gave the same "no flash on target change" property, but some sites (e.g.
# UVA's own signage CMS) send X-Frame-Options and simply refuse to render
# inside anyone else's frame, which broke displaying them at all. Real
# top-level tabs have no such restriction. Before the iframe, this script
# just killed and relaunched Chromium itself for every target change, which
# is what caused the original black/white flash - going back to that
# wasn't necessary once tab-swapping-in-place was possible. Runs as the X
# client under `startx` - see kiosk.service.
#
# The 03-splash stage's Plymouth theme covers the kernel-boot phase before
# this script even runs, quitting at the normal systemd handoff point
# (Plymouth and X both need exclusive control of the display, so Plymouth's
# splash necessarily disappears the instant X starts - it can't be kept
# alive through this next part). What covers the gap from there instead is
# `feh` showing a branded image full-screen: confirmed live on the dev unit
# that Chromium's own cold start - spinning up its GPU/zygote/renderer
# processes - takes 10-15+ seconds on this hardware, and nothing can paint
# real content on screen until that finishes, which is what caused the
# black/white flicker loading.html alone couldn't cover (it's a page inside
# Chromium, so it can't render anything before Chromium itself is ready
# either). `feh` starts in milliseconds since it isn't Chromium, so it can
# actually be on screen for that whole gap - see launch_boot_splash() below,
# stopped only once Chromium's own DevTools Protocol confirms loading.html
# has actually been navigated to (see wait_for_loading_html_ready()), not
# just that the process exists.

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
DASHBOARD_DOWN_TEMPLATE="/etc/kiosk/dashboard-down.html"
DASHBOARD_DOWN_RENDERED="/tmp/kiosk-dashboard-down.html"
LOADING_PAGE="/etc/kiosk/loading.html"
STATUS_FILE="/tmp/kiosk-status.json"
WLAN_IFACE="wlan0"
CHECK_INTERVAL=15
CDP_PORT=9222
CDP_TAB_SWAP="/etc/kiosk/cdp-tab-swap.py"
SWAP_TIMEOUT=15
BOOT_SPLASH_IMAGE="/etc/kiosk/kiosk-boot-splash.png"
# Used only to tell "no internet at all" apart from "internet's fine, but
# utsopsdashboard.com itself isn't answering" when checkin() fails - plain
# IPs, not hostnames, so this doesn't depend on DNS working. Three of them
# (two providers) so one outage/blackhole among them can't cause a false
# "not connected" reading. Checked over HTTPS via curl (not ping/ICMP):
# no new package dependency beyond what's already installed, and some
# networks filter ICMP separately from HTTPS, which would give a false
# "not connected" reading on a network that's actually fine.
KNOWN_GOOD_IPS="1.1.1.1 1.0.0.1 8.8.8.8"

FEH_PID=""

# Launched first, before even X housekeeping below, so it's on screen as
# soon as physically possible after the Plymouth handoff. feh's fullscreen
# windows are override-redirect, so this works with no window manager
# running yet. Degrades safely (just no splash, straight to whatever X's
# default background is) if feh isn't installed - lets this script keep
# working on an image that hasn't been rebuilt with the feh package yet.
launch_boot_splash() {
  if ! command -v feh >/dev/null 2>&1; then
    log "feh not installed, skipping boot splash overlay"
    return
  fi
  feh --fullscreen --hide-pointer --image-bg '#232D4B' "$BOOT_SPLASH_IMAGE" &
  FEH_PID=$!
  log "boot splash (feh) launched, pid=$FEH_PID"
}

stop_boot_splash() {
  [ -n "$FEH_PID" ] || return
  kill "$FEH_PID" 2>/dev/null
  wait "$FEH_PID" 2>/dev/null
  log "boot splash (feh) stopped"
  FEH_PID=""
}

launch_boot_splash

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

# Probes a couple of known-good IPs (not the dashboard) to tell a real
# connectivity problem apart from the dashboard itself being down/unreachable
# (deploy issue, outage, etc). Any single response is enough - this only
# needs to answer "is there a path to the internet at all".
internet_reachable() {
  local ip
  for ip in $KNOWN_GOOD_IPS; do
    if curl -sS -k --max-time 3 -o /dev/null "https://${ip}/"; then
      return 0
    fi
  done
  return 1
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
# (online, but nothing assigned at all), or - if the check-in request itself
# failed - either the "dashboard unreachable" page (internet's fine, just
# utsopsdashboard.com isn't answering) or the "not connected" page (no
# internet at all), decided by internet_reachable(). Reads whatever
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
    if internet_reachable; then
      render_page "$DASHBOARD_DOWN_TEMPLATE" "$DASHBOARD_DOWN_RENDERED"
      echo "file://${DASHBOARD_DOWN_RENDERED}"
    else
      render_page "$FALLBACK_TEMPLATE" "$FALLBACK_RENDERED"
      echo "file://${FALLBACK_RENDERED}"
    fi
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

# Publishes the current decision. loading.html no longer reads this (see
# swap_to() below for how the actual on-screen tab changes now) - this
# purely exists so kiosk-self-update.sh can read CHECKIN_CHANNEL over the
# same local HTTP endpoint without a separate check-in call of its own, plus
# it's a handy `curl 127.0.0.1:8765/status.json` for debugging what this
# script currently thinks should be showing. Atomic write (tmp + rename) so
# kiosk-status-server.py never serves a half-written file mid-update.
write_status() {
  jq -n --arg target "$1" --arg channel "$CHECKIN_CHANNEL" \
    '{target: $target, channel: $channel}' > "${STATUS_FILE}.tmp"
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Finds the tab CDP-wise ID of whatever's currently showing loading.html -
# used as the "old" tab to close once the first real target is ready to
# swap in.
get_loading_tab_id() {
  curl -fsS --max-time 2 "http://127.0.0.1:${CDP_PORT}/json" 2>/dev/null \
    | jq -r --arg u "file://${LOADING_PAGE}" '[.[] | select(.url == $u)][0].id // empty'
}

CURRENT_TARGET=""
CURRENT_TAB_ID=""

# Swaps the on-screen tab to $1 by opening it as a genuine new top-level tab,
# waiting for it to load, activating it, and closing whatever tab
# CURRENT_TAB_ID points at - see cdp-tab-swap.py for why this needs a real
# CDP WebSocket connection rather than just the HTTP /json endpoints. Leaves
# CURRENT_TARGET/CURRENT_TAB_ID untouched on failure (logged, not fatal) so
# whatever's already on screen just keeps showing rather than getting stuck
# mid-swap - the next watchdog tick will simply try again if the target is
# still supposed to change.
swap_to() {
  local target="$1" new_id log_output
  # 2>&1 1>file swaps the streams: cdp-tab-swap.py's log lines (stderr) end
  # up in $log_output via this command substitution, while its one line of
  # real output - the new tab's id (stdout) - lands in the file instead.
  log_output="$(python3 "$CDP_TAB_SWAP" --port "$CDP_PORT" --url "$target" \
    ${CURRENT_TAB_ID:+--old-id "$CURRENT_TAB_ID"} --timeout "$SWAP_TIMEOUT" \
    2>&1 1>/tmp/kiosk-cdp-new-id)"
  [ -n "$log_output" ] && log "cdp-tab-swap: $log_output"
  new_id="$(cat /tmp/kiosk-cdp-new-id 2>/dev/null)"
  if [ -n "$new_id" ]; then
    CURRENT_TAB_ID="$new_id"
    CURRENT_TARGET="$target"
    log "swapped to $target (tab $new_id)"
  else
    log "tab swap to $target failed, leaving current tab showing"
  fi
}

# chrome://gpu confirmed GPU rasterization/compositing are already hardware
# accelerated by default on this build (Debian's packaged Chromium already
# passes --enable-gpu-rasterization/--use-angle=gles itself) - no override
# needed there. The last line instead disables Site Isolation: it spawns a
# separate renderer process per origin as a defense against cross-site data
# leaks, which costs real memory for no benefit on a kiosk that only ever
# shows content inside one fixed, trusted top-level shell page.
# --remote-debugging-port binds to 127.0.0.1 only (no
# --remote-debugging-address override) - purely local, used below to ask
# Chromium itself whether loading.html has actually loaded yet, not exposed
# on the network. Adds no meaningful attack surface beyond what RustDesk's
# full remote-desktop access already grants on this device.
# --mute-audio: kiosk displays aren't meant to have sound (2026-08-25) - one
# flag, trivially reversible by dropping it and rebuilding.
CHROMIUM_FLAGS="--kiosk --incognito --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --disable-translate --no-first-run \
  --check-for-update-interval=31536000 --overscroll-history-navigation=0 \
  --autoplay-policy=no-user-gesture-required --window-position=0,0 \
  --disable-features=IsolateOrigins,site-per-process --mute-audio \
  --remote-debugging-port=${CDP_PORT}"

CHROMIUM_PID=""

launch_chromium() {
  log "launching chromium"
  chromium $CHROMIUM_FLAGS "file://${LOADING_PAGE}" &
  CHROMIUM_PID=$!
  log "chromium launched, pid=$CHROMIUM_PID"
}

# Polls Chromium's own DevTools Protocol - which reports what Chromium
# itself has actually navigated to, not a guess based on elapsed time -
# until it sees a target whose url is loading.html. Bounded so a CDP hiccup
# (port conflict, endpoint slow to bind) can never leave the boot splash
# stuck on screen forever; on timeout it just gives up and reveals whatever
# Chromium currently has anyway.
wait_for_loading_html_ready() {
  local deadline target_url
  target_url="file://${LOADING_PAGE}"
  deadline=$(( $(date +%s) + 25 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS --max-time 1 "http://127.0.0.1:${CDP_PORT}/json" 2>/dev/null \
      | jq -e --arg u "$target_url" 'any(.[]?; .url == $u)' >/dev/null 2>&1; then
      log "loading.html confirmed rendered via CDP"
      return
    fi
    sleep 0.3
  done
  log "timed out waiting for CDP confirmation of loading.html, revealing anyway"
}

# Chromium launches exactly once, always at loading.html - decide_target()
# and swap_to() below are what actually put the real target on screen, and
# keep it current as long as this script keeps running.
log "kiosk-launch.sh starting"
launch_chromium
wait_for_loading_html_ready
stop_boot_splash

# Initial grace period for WiFi/cellular to associate, so a normal boot
# doesn't briefly surface the "not connected" fallback before settling on
# the real dashboard. loading.html just sits there showing the splash until
# the first swap_to() call below, so there's no real cost to waiting the
# full period out here.
for _ in 1 2 3 4 5 6 7 8 9; do
  checkin
  [ "$CHECKIN_OK" = "1" ] && break
  sleep 5
done

FIRST_TARGET="$(decide_target)"
log "initial target: $FIRST_TARGET"
write_status "$FIRST_TARGET"
CURRENT_TAB_ID="$(get_loading_tab_id)"
swap_to "$FIRST_TARGET"

# Watchdog: keep STATUS_FILE current, swap the on-screen tab when the
# decided target actually changes, and restart Chromium from scratch if it
# dies outright (crash recovery, not a target change - a dead Chromium
# process takes every tab down with it, so this re-runs the same
# loading.html -> swap_to() sequence as a fresh boot).
while true; do
  sleep "$CHECK_INTERVAL"
  checkin
  TARGET="$(decide_target)"
  write_status "$TARGET"
  if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
    log "chromium (pid $CHROMIUM_PID) is not running, relaunching"
    launch_boot_splash
    launch_chromium
    wait_for_loading_html_ready
    stop_boot_splash
    CURRENT_TARGET=""
    CURRENT_TAB_ID="$(get_loading_tab_id)"
    swap_to "$TARGET"
  elif [ "$TARGET" != "$CURRENT_TARGET" ]; then
    swap_to "$TARGET"
  fi
done
