#!/bin/bash -e

install -v -m 755 -o root -g root -d "${ROOTFS_DIR}/etc/kiosk"

install -v -m 755 -o root -g root files/rustdesk-provision.sh \
	"${ROOTFS_DIR}/etc/kiosk/rustdesk-provision.sh"
install -v -m 600 -o root -g root files/rustdesk-password \
	"${ROOTFS_DIR}/etc/kiosk/rustdesk-password"
install -v -m 644 -o root -g root files/rustdesk-provision.service \
	"${ROOTFS_DIR}/etc/systemd/system/rustdesk-provision.service"
