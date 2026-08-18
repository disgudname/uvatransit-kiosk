#!/bin/bash -e

install -v -m 644 -o root -g root files/zramswap "${ROOTFS_DIR}/etc/default/zramswap"
install -v -m 644 -o root -g root files/99-kiosk-swappiness.conf \
	"${ROOTFS_DIR}/etc/sysctl.d/99-kiosk-swappiness.conf"
