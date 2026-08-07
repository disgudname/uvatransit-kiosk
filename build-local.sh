#!/bin/bash -e
# Builds the UVA Transit kiosk image via pi-gen, using Docker.
#
# Must be run from inside a real Linux environment (WSL2's Ubuntu terminal on
# Windows, not Git Bash/PowerShell directly) - pi-gen needs kernel features
# (binfmt_misc, loop devices) that only exist there.
#
# Usage: ./build-local.sh
# Output: ./deploy/*.img.xz

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if grep -q "CHANGE-ME-BEFORE-BUILDING" config; then
	echo "ERROR: config still has the placeholder FIRST_USER_PASS. Edit config and set a real password before building." >&2
	exit 1
fi

if grep -q "CHANGE-ME-BEFORE-BUILDING" stage-kiosk/02-rustdesk/files/rustdesk-password; then
	echo "ERROR: stage-kiosk/02-rustdesk/files/rustdesk-password still has the placeholder value. Set a real RustDesk password before building." >&2
	exit 1
fi

echo "Syncing stage-kiosk/ into pi-gen/ (pi-gen's Docker build only sees files inside its own directory)..."
rm -rf pi-gen/stage-kiosk
cp -r stage-kiosk pi-gen/stage-kiosk

echo "Building (this can take 30-60+ minutes the first time)..."
./pi-gen/build-docker.sh -c "$DIR/config"

echo "Done. Image(s) are in $DIR/deploy/"
