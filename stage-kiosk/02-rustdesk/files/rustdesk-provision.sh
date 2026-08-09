#!/bin/bash -e
# Applies the fixed permanent password to RustDesk and records this device's
# RustDesk ID onto the boot partition, so it can be read (by pulling the SD
# card) even before anyone has remoted in for the first time.

PASSWORD_FILE="/etc/kiosk/rustdesk-password"
ID_OUT="/boot/firmware/rustdesk-id.txt"

if [ ! -s "$PASSWORD_FILE" ]; then
	echo "rustdesk-provision: no password set in $PASSWORD_FILE, skipping" >&2
	exit 0
fi

for _ in $(seq 1 30); do
	systemctl is-active --quiet rustdesk && break
	sleep 2
done

# Wait for RustDesk to finish its own first-run config bootstrap (a non-empty
# ID means its config/keypair genuinely exists) before setting the password -
# setting it too early can get silently dropped once the daemon finishes
# initializing and (re)writes its config.
ID=""
for _ in $(seq 1 15); do
	ID="$(rustdesk --get-id 2>/dev/null || true)"
	[ -n "$ID" ] && break
	sleep 2
done

if [ -n "$ID" ]; then
	echo "$ID" > "$ID_OUT"
fi

# `rustdesk --password` talks to the already-running daemon over a local IPC
# socket with only a ~1s timeout, with no fallback if that daemon isn't ready
# yet to accept connections - and critically, it prints "Done!" on success or
# an error message on failure but exits 0 either way, so the exit code can't
# be used to detect failure. Check the actual output instead.
PASSWORD="$(cat "$PASSWORD_FILE")"
for _ in $(seq 1 20); do
	OUTPUT="$(rustdesk --password "$PASSWORD" 2>&1)"
	case "$OUTPUT" in
		*Done*) break ;;
	esac
	sleep 2
done
