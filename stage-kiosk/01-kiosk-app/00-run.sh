#!/bin/bash -e

install -v -m 755 -o root -g root -d "${ROOTFS_DIR}/etc/kiosk"

install -v -m 755 -o root -g root files/kiosk-launch.sh "${ROOTFS_DIR}/etc/kiosk/kiosk-launch.sh"
install -v -m 644 -o root -g root files/mac-fallback.html "${ROOTFS_DIR}/etc/kiosk/mac-fallback.html"
install -v -m 644 -o root -g root files/not-registered.html "${ROOTFS_DIR}/etc/kiosk/not-registered.html"
install -v -m 644 -o root -g root files/loading.html "${ROOTFS_DIR}/etc/kiosk/loading.html"

# Records when this specific image was built, reported to the dashboard on
# every check-in so a device's running image version is visible fleet-wide.
date -u +%Y-%m-%dT%H:%M:%SZ > "${ROOTFS_DIR}/etc/kiosk/image-build.txt"

sed "s/KIOSK_USER_PLACEHOLDER/${FIRST_USER_NAME}/g" files/kiosk.service \
	> "${ROOTFS_DIR}/etc/systemd/system/kiosk.service"
chmod 644 "${ROOTFS_DIR}/etc/systemd/system/kiosk.service"

install -v -m 600 -o root -g root files/wahoo.nmconnection \
	"${ROOTFS_DIR}/etc/NetworkManager/system-connections/wahoo.nmconnection"

install -v -m 644 -o root -g root files/cron-kiosk-reboot "${ROOTFS_DIR}/etc/cron.d/kiosk-reboot"

# No boot text and no generic Pi rainbow logo - the 03-splash stage's branded
# Plymouth theme is what shows instead (`splash` below is what tells the kernel
# to hand the framebuffer to Plymouth rather than printing text).
BOOT_CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
BOOT_CMDLINE_TXT="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
echo "disable_splash=1" >> "${BOOT_CONFIG_TXT}"
sed -i 's/$/ quiet splash loglevel=3 logo.nologo vt.global_cursor_default=0/' "${BOOT_CMDLINE_TXT}"

# Manual fallback/override, only used when the ops dashboard hasn't assigned a
# site code to this device's MAC yet (e.g. testing at home). Safe to leave blank.
touch "${ROOTFS_DIR}/boot/firmware/site-code.txt"
