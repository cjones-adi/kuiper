#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# LM75 + PWM-fan "Hello World" -- OpenBMC observation glue.
#
# The OpenBMC framework (bmcweb, phosphor-objmgr, phosphor-hwmon, the bmc-assoc
# binary + service, usermgr, D-Bus policy, PAM, the 'redfish' group, webui-vue)
# is already installed and enabled by 07/09.openbmc-stack. This stage ONLY adds
# the per-device glue so the LM75 temperature and the fan RPM appear under
# Redfish / the web UI as Chassis "lm75-demo":
#   - two phosphor-hwmon instances (lm75 -> temperature; pwmfan -> fan RPM)
#   - a bmc-assoc drop-in that publishes the chassis + sensor associations
#
# The fan CONTROL loop is kernel-side (thermal zone from 06.04.lm75-fan-overlay);
# OpenBMC only observes. Runs AFTER 09.openbmc-stack ("10" sorts after "09").
#
# Runs from the Kuiper root (kuiper-stages.sh: `bash -e ${script}`).
set -e

STAGE_DIR="$(dirname "$0")"
FILES="${STAGE_DIR}/files"

if [ "${CONFIG_RPI_BOOT_FILES}" != y ]; then
	echo "10.lm75-fan: CONFIG_RPI_BOOT_FILES != y, skipping."
	exit 0
fi

echo "10.lm75-fan: installing LM75 + PWM-fan observation glue"

# --- phosphor-hwmon config templates ----------------------------------------
# Installed at first boot to the OF-path-derived %I location the hwmon template
# unit expects, by the generic setup script below.
install -Dm644 "${FILES}/lm75-hwmon.conf"   "${BUILD_DIR}/usr/share/lm75-fan/lm75-hwmon.conf"
install -Dm644 "${FILES}/pwmfan-hwmon.conf" "${BUILD_DIR}/usr/share/lm75-fan/pwmfan-hwmon.conf"

# Generic first-boot instantiator (hwmon-name + template as args) -- the proven
# adm1600 discovery logic, parameterized so one script serves both devices.
install -Dm755 "${FILES}/obmc-hwmon-dev-setup.sh" \
	"${BUILD_DIR}/usr/bin/obmc-hwmon-dev-setup.sh"

install -Dm644 "${FILES}/obmc-hwmon-lm75.service" \
	"${BUILD_DIR}/usr/lib/systemd/system/obmc-hwmon-lm75.service"
install -Dm644 "${FILES}/obmc-hwmon-pwmfan.service" \
	"${BUILD_DIR}/usr/lib/systemd/system/obmc-hwmon-pwmfan.service"

# --- bmc-assoc drop-in: chassis "lm75-demo" + sensor associations -----------
# bmc-assoc.service (installed + enabled by 09.openbmc-stack) reads
# /etc/bmc-assoc/*.conf at boot, so this drop-in is all that is needed here --
# no re-enable, no recompile.
install -Dm644 "${FILES}/bmc-assoc-lm75-demo.conf" \
	"${BUILD_DIR}/etc/bmc-assoc/lm75-demo.conf"

# --- Enable the two hwmon instantiators -------------------------------------
chroot "${BUILD_DIR}" systemctl enable \
	obmc-hwmon-lm75.service \
	obmc-hwmon-pwmfan.service

echo "10.lm75-fan: done."
echo "  After boot (LM75 at 0x48 + 4-pin fan wired):"
echo "    curl -k https://<pi-ip>/redfish/v1/Chassis/lm75-demo/Sensors"
