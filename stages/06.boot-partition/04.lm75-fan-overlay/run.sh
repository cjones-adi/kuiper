#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# LM75 + PWM-fan "Hello World" thermal demo -- boot/kernel collateral.
# (Option K: the control loop runs in the KERNEL thermal framework.)
#
# Adds, on top of the kernel installed by 06.03.adm1600-kernel:
#   - an LM75 temp sensor on I2C1 (0x48)
#   - a 4-pin PWM fan on GPIO18 (PWM0) with tach on GPIO23
#   - a Linux thermal zone that drives the fan from the LM75 (step_wise governor)
#
# This stage does NOT rebuild the kernel: lm75 / pwm-fan / pwm-bcm2835 already
# ship as modules in the 6.12.41-v8+ kernel from 06.03, so it must run AFTER it
# (it does: "04" sorts after "03"). The OpenBMC observation glue is 07/10.lm75-fan.
#
# Runs from the Kuiper root (kuiper-stages.sh: `bash -e ${script}`).
set -e

STAGE_DIR="$(dirname "$0")"
FILES="${STAGE_DIR}/files"

if [ "${CONFIG_RPI_BOOT_FILES}" != y ]; then
	echo "04.lm75-fan-overlay: CONFIG_RPI_BOOT_FILES != y, skipping."
	exit 0
fi

echo "04.lm75-fan-overlay: building + installing the lm75-fan device-tree overlay"

# --- 1. Compile the overlay in the chroot. dtc -@ keeps the __fixups__ so the
#        RPi bootloader resolves &i2c1/&pwm/&gpio against the base DTB at boot. --
install -Dm644 "${FILES}/lm75-fan-overlay.dts" "${BUILD_DIR}/tmp/lm75-fan-overlay.dts"
chroot "${BUILD_DIR}" /bin/bash -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive
if ! command -v dtc >/dev/null 2>&1; then
	apt-get update
	apt-get install -y --no-install-recommends device-tree-compiler
fi
mkdir -p /boot/overlays
dtc -@ -I dts -O dtb -o /boot/overlays/lm75-fan.dtbo /tmp/lm75-fan-overlay.dts
rm -f /tmp/lm75-fan-overlay.dts
EOF

# Keep /boot/firmware/overlays consistent if raspi-firmware created it.
if [ -d "${BUILD_DIR}/boot/firmware/overlays" ]; then
	cp "${BUILD_DIR}/boot/overlays/lm75-fan.dtbo" "${BUILD_DIR}/boot/firmware/overlays/"
fi

# --- 2. config.txt: enable PWM0 on GPIO18 + load the lm75-fan overlay --------
CFG="${BUILD_DIR}/boot/config.txt"
if [ -f "${CFG}" ]; then
	sed -i '/^dtoverlay=pwm,pin=18,func=2$/d;/^dtoverlay=lm75-fan$/d' "${CFG}"
	cat >> "${CFG}" <<'EOF'

# --- LM75 + PWM-fan Hello-World demo (added by 04.lm75-fan-overlay) ---
# [all] re-asserts the unconditional filter (see 03.adm1600-kernel) so these
# overlays are not swallowed by a trailing [cm5]/conditional section on a Pi4.
# dtoverlay=pwm sets GPIO18 to ALT5 (PWM0, 25kHz); lm75-fan adds the sensor, the
# pwm-fan cooling device (+tach on GPIO23) and the thermal zone (the control loop).
[all]
dtoverlay=pwm,pin=18,func=2
dtoverlay=lm75-fan
EOF
	[ -f "${BUILD_DIR}/boot/firmware/config.txt" ] && \
		cp "${CFG}" "${BUILD_DIR}/boot/firmware/config.txt"
else
	echo "WARNING: ${CFG} not found; lm75-fan overlay not enabled." 1>&2
fi

# --- 3. Autoload the demo modules (i2c core already handled by 06.03) --------
install -Dm644 /dev/stdin "${BUILD_DIR}/etc/modules-load.d/lm75-fan.conf" <<'EOF'
# lm75-fan demo: usually autoloaded by DT modalias once the overlay instantiates
# the nodes; listed explicitly so bus/PWM/sensor come up regardless of timing.
pwm-bcm2835
pwm-fan
lm75
EOF

echo "04.lm75-fan-overlay: done (overlay + config.txt + modules-load installed)."
