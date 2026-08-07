#!/bin/bash -e

DEB_URL="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
	| grep -oE 'https://[^"]+-aarch64\.deb' | head -n1)"

if [ -z "$DEB_URL" ]; then
	echo "Could not find a RustDesk aarch64 .deb in the latest GitHub release" >&2
	exit 1
fi

curl -fsSL -o /tmp/rustdesk.deb "$DEB_URL"
apt-get update
apt-get install -y /tmp/rustdesk.deb
rm -f /tmp/rustdesk.deb

systemctl enable rustdesk
systemctl enable rustdesk-provision.service
