#!/bin/bash
# Generic phosphor-hwmon first-boot instantiator.
#
#   obmc-hwmon-dev-setup.sh <hwmon-name> <template-conf>
#
# Discovers the hwmon class device whose `name` == <hwmon-name>, installs its
# phosphor-hwmon config at the device-tree-path-derived location the systemd
# template unit expects (%I), then starts the poller. Idempotent.
#
# Why runtime discovery: phosphor-hwmon's unit is xyz.openbmc_project.Hwmon@%I,
# where %I is the device's OF path (see start_hwmon.sh). That path is only known
# on the booted Pi, so we compute it here rather than hardcoding at build time.
#
# This is the proven adm1600 setup logic, parameterized so one script serves both
# the LM75 (name "lm75") and the PWM fan (name "pwmfan").
set -euo pipefail

NAME="${1:?usage: $0 <hwmon-name> <template-conf>}"
TEMPLATE="${2:?usage: $0 <hwmon-name> <template-conf>}"
CONFROOT=/etc/default/obmc/hwmon

# 1. Locate the hwmon class device by name
hwmon=""
for d in /sys/class/hwmon/hwmon*; do
	[ -r "$d/name" ] || continue
	if [ "$(cat "$d/name")" = "$NAME" ]; then hwmon="$d"; break; fi
done
if [ -z "$hwmon" ]; then
	echo "ERROR: '$NAME' hwmon device not found (driver bound? overlay loaded?)" >&2
	exit 1
fi
echo "Found $NAME hwmon: $hwmon"

# 2. Derive the OF (device-tree) path backing the device
ofnode="$hwmon/device/of_node"
if [ -e "$ofnode" ]; then
	full="$(readlink -f "$ofnode")"                 # /sys/firmware/devicetree/base/...
	ofpath="${full#/sys/firmware/devicetree/base}"  # /soc/.../lm75@48  or  /pwm-fan
else
	dp="$(readlink -f "$hwmon/device")"             # fallback: /sys devpath
	ofpath="${dp#/sys}"
fi
echo "Device OF/dev path: $ofpath"

# 3. Reproduce start_hwmon.sh escaping so we match the unit + %I conf path
colon="${ofpath//:/--}"           # equals systemd %I (unescaped instance)
esc="$(systemd-escape "$colon")"  # equals the @<instance> token in the unit name

# 4. Install the conf at the %I path
conf="${CONFROOT}${colon}.conf"
install -d "$(dirname "$conf")"
install -m644 "$TEMPLATE" "$conf"
echo "Installed config: $conf"

# 5. Start the poller instance
unit="xyz.openbmc_project.Hwmon@${esc}.service"
systemctl start "$unit"
echo "Started $unit"
