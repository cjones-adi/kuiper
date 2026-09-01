#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Override Kuiper's prebuilt ADI rpi-6.6.y kernel with the locally-built
# rpi-6.12.y_adm1600 arm64 kernel (CONFIG_SENSORS_ADM1600=y, built-in) so the
# ADM1600 PMBus driver is present at boot and exposes hwmon sysfs.
#
# Artifacts are staged into kuiper-volume/adm1600-kernel by
# ../../../stage-adm1600-kernel.sh (run on the HOST before build-docker.sh).
# kuiper-volume is bind-mounted at /kuiper-volume inside the build container.
#
# Runs AFTER 06.boot-partition/02.rpi-boot-files, which installed the ADI kernel
# (via `apt-get install adi-rpi-boot`) into ${BUILD_DIR}/boot and
# ${BUILD_DIR}/lib/modules. This stage replaces those.

set -e

SRC="/kuiper-volume/adm1600-kernel"

if [ "${CONFIG_RPI_BOOT_FILES}" != y ]; then
	echo "03.adm1600-kernel: CONFIG_RPI_BOOT_FILES != y, skipping."
	exit 0
fi

if [ ! -f "${SRC}/KERNEL_RELEASE" ]; then
	echo "ERROR: ${SRC} not staged. Run ./stage-adm1600-kernel.sh on the host first." 1>&2
	exit 1
fi

KREL="$(cat "${SRC}/KERNEL_RELEASE")"
echo "Installing ADM1600 kernel ${KREL} (overriding ADI rpi-6.6.y)"

# --- Boot files: ${BUILD_DIR}/boot is the FAT boot partition (see
#     08.export-stage/04.export-image rsync of ${BUILD_DIR}/boot). The 64-bit
#     RPi firmware loads /boot/kernel8.img. ---
BOOTDST="${BUILD_DIR}/boot"
install -m644 "${SRC}/boot/kernel8.img" "${BOOTDST}/kernel8.img"
install -m644 "${SRC}/boot/"*.dtb "${BOOTDST}/"
mkdir -p "${BOOTDST}/overlays"
cp "${SRC}/boot/overlays/"*.dtbo "${BOOTDST}/overlays/"
[ -f "${SRC}/boot/overlays/overlay_map.dtb" ] && \
	cp "${SRC}/boot/overlays/overlay_map.dtb" "${BOOTDST}/overlays/"

# Keep /boot/firmware consistent if raspi-firmware created it.
if [ -d "${BUILD_DIR}/boot/firmware" ]; then
	install -m644 "${SRC}/boot/kernel8.img" "${BUILD_DIR}/boot/firmware/kernel8.img"
	install -m644 "${SRC}/boot/"*.dtb "${BUILD_DIR}/boot/firmware/"
	mkdir -p "${BUILD_DIR}/boot/firmware/overlays"
	cp "${SRC}/boot/overlays/"*.dtbo "${BUILD_DIR}/boot/firmware/overlays/"
fi

# --- Kernel modules: drop the ADI 6.6.y modules, install ours ---
rm -rf "${BUILD_DIR}/lib/modules"/*
mkdir -p "${BUILD_DIR}/lib/modules"
cp -a "${SRC}/lib/modules/${KREL}" "${BUILD_DIR}/lib/modules/"

# Rebuild modules.dep/alias against this rootfs so udev can autoload modules by
# modalias (e.g. i2c_bcm2835 off the DT) and `modprobe` resolves cleanly.
chroot "${BUILD_DIR}" depmod "${KREL}"

# --- I2C userspace support ------------------------------------------------
# i2c-dev and i2c-bcm2835 are built as modules in this kernel. i2c-dev is never
# autoloaded (it is the /dev/i2c-* shim that i2cdetect/phosphor-hwmon need), and
# i2c-bcm2835 is forced too so the bus is up regardless of DT modalias timing.
install -Dm644 /dev/stdin "${BUILD_DIR}/etc/modules-load.d/adm1600-i2c.conf" <<'EOF'
# ADM1600 bring-up: I2C bus controller + userspace char-dev interface
i2c-bcm2835
i2c-dev
EOF

# i2c-tools (i2cdetect/i2cget/i2cset) for manual verification of the ADM1600 at 0x48
chroot "${BUILD_DIR}" /bin/bash -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends i2c-tools
EOF

# --- config.txt: pin our kernel, enable I2C + load the ADM1600 overlay ---
CFG="${BUILD_DIR}/boot/config.txt"
if [ -f "${CFG}" ]; then
	sed -i '/^kernel=/d;/^dtoverlay=adm1600/d;/^dtparam=i2c_arm=/d' "${CFG}"
	cat >> "${CFG}" <<'EOF'

# --- ADM1600 BMC kernel + sensor overlay (added by 03.adm1600-kernel) ---
# [all] resets any preceding conditional filter (the base config.txt ends in a
# [cm5] section); without it these lines inherit that filter and are silently
# skipped on a Pi4, leaving no /dev/i2c-1 and no adm1600 in /sys/class/hwmon.
[all]
kernel=kernel8.img
dtparam=i2c_arm=on
dtoverlay=adm1600
EOF
	[ -f "${BUILD_DIR}/boot/firmware/config.txt" ] && \
		cp "${CFG}" "${BUILD_DIR}/boot/firmware/config.txt"
else
	echo "WARNING: ${CFG} not found; ADM1600 overlay not enabled." 1>&2
fi

echo "ADM1600 kernel ${KREL} installed; I2C + adm1600 overlay enabled."
