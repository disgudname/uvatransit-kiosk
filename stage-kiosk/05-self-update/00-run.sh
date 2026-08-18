#!/bin/bash -e

install -v -m 755 -o root -g root files/kiosk-self-update.sh "${ROOTFS_DIR}/etc/kiosk/kiosk-self-update.sh"
install -v -m 644 -o root -g root files/kiosk-self-update.service \
	"${ROOTFS_DIR}/etc/systemd/system/kiosk-self-update.service"
install -v -m 644 -o root -g root files/kiosk-self-update.timer \
	"${ROOTFS_DIR}/etc/systemd/system/kiosk-self-update.timer"
