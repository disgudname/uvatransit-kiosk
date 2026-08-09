#!/bin/bash -e

install -v -m 755 -o root -g root -d "${ROOTFS_DIR}/usr/share/plymouth/themes/uvatransit"

install -v -m 644 -o root -g root files/uvatransit.plymouth files/uvatransit.script \
	files/logo.png files/progress-box.png files/progress-bar.png \
	"${ROOTFS_DIR}/usr/share/plymouth/themes/uvatransit/"
