#!/bin/bash -e

install -v -m 755 -o root -g root -d "${ROOTFS_DIR}/etc/kiosk"

install -v -m 755 -o root -g root files/kiosk-launch.sh "${ROOTFS_DIR}/etc/kiosk/kiosk-launch.sh"
install -v -m 644 -o root -g root files/mac-fallback.html "${ROOTFS_DIR}/etc/kiosk/mac-fallback.html"

sed "s/KIOSK_USER_PLACEHOLDER/${FIRST_USER_NAME}/g" files/kiosk.service \
	> "${ROOTFS_DIR}/etc/systemd/system/kiosk.service"
chmod 644 "${ROOTFS_DIR}/etc/systemd/system/kiosk.service"

install -v -m 600 -o root -g root files/wahoo.nmconnection \
	"${ROOTFS_DIR}/etc/NetworkManager/system-connections/wahoo.nmconnection"

install -v -m 644 -o root -g root files/cron-kiosk-reboot "${ROOTFS_DIR}/etc/cron.d/kiosk-reboot"

# Quieter boot: skip the rainbow splash / boot text, matching chilipie-kiosk's original intent.
BOOT_CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
BOOT_CMDLINE_TXT="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
echo "disable_splash=1" >> "${BOOT_CONFIG_TXT}"
sed -i 's/$/ quiet loglevel=3 logo.nologo vt.global_cursor_default=0/' "${BOOT_CMDLINE_TXT}"

# Placeholder the site operator drops a code into (e.g. "EIGSB") to pick which
# bus stop this device displays; safe to leave blank until deployment.
touch "${ROOTFS_DIR}/boot/firmware/site-code.txt"
