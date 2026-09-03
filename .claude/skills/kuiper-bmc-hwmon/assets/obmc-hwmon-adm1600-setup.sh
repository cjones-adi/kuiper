#!/bin/bash
# Discover the ADM1600 hwmon instance at runtime, install its phosphor-hwmon
# config at the device-tree-path-derived location that the systemd template
# unit expects (%I), then start the poller. Idempotent — safe to re-run.
#
# Why runtime discovery: phosphor-hwmon's unit is xyz.openbmc_project.Hwmon@%I
# where %I is the device's OF path (see start_hwmon.sh). That path is only known
# on the booted Pi, so we compute it here rather than hardcoding it at build.
set -euo pipefail

TEMPLATE=/usr/share/adm1600/adm1600-hwmon.conf
CONFROOT=/etc/default/obmc/hwmon

# 1. Locate the adm1600 hwmon class device
hwmon=""
for d in /sys/class/hwmon/hwmon*; do
	[ -r "$d/name" ] || continue
	if [ "$(cat "$d/name")" = "adm1600" ]; then hwmon="$d"; break; fi
done
if [ -z "$hwmon" ]; then
	echo "ERROR: adm1600 hwmon device not found (is CONFIG_SENSORS_ADM1600 bound and the overlay loaded?)" >&2
	exit 1
fi
echo "Found ADM1600 hwmon: $hwmon"

# 2. Derive the OF (device-tree) path backing the device
ofnode="$hwmon/device/of_node"
if [ -e "$ofnode" ]; then
	full="$(readlink -f "$ofnode")"                 # /sys/firmware/devicetree/base/soc/.../adm1600@48
	ofpath="${full#/sys/firmware/devicetree/base}"  # /soc/.../adm1600@48
else
	# Fallback: /sys devpath minus the trailing /hwmon/hwmonN
	dp="$(readlink -f "$hwmon/device")"
	ofpath="${dp#/sys}"
fi
echo "Device OF/dev path: $ofpath"

# 3. Reproduce start_hwmon.sh escaping so we match the unit + %I conf path
colon="${ofpath//:/--}"           # equals systemd %I (unescaped instance)
esc="$(systemd-escape "$colon")"  # equals the @<instance> token in the unit name

# 4. Install the conf at the %I path (ConditionFileNotEmpty=/etc/default/obmc/hwmon/%I.conf)
conf="${CONFROOT}${colon}.conf"
install -d "$(dirname "$conf")"
install -m644 "$TEMPLATE" "$conf"
echo "Installed config: $conf"

# 5. Start the poller instance
unit="xyz.openbmc_project.Hwmon@${esc}.service"
systemctl start "$unit"
echo "Started $unit"
