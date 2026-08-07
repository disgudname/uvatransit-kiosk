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

rustdesk --password "$(cat "$PASSWORD_FILE")" || true

ID=""
for _ in $(seq 1 15); do
	ID="$(rustdesk --get-id 2>/dev/null || true)"
	[ -n "$ID" ] && break
	sleep 2
done

if [ -n "$ID" ]; then
	echo "$ID" > "$ID_OUT"
fi
