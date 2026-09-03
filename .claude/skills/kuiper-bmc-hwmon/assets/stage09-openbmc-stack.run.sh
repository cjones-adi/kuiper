#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Install the from-source OpenBMC D-Bus -> Redfish stack (bmcweb + phosphor-hwmon
# + phosphor-objmgr) into the Kuiper rootfs and wire it to the ADM1600 so its
# sensors appear under Redfish.
#
# The heavy arm64 stack is PRE-BUILT on the host (emulated build takes hours),
# same pattern as the ADM1600 kernel stage. Produce the tarball first with:
#   docker exec obmc-build bash -lc 'cd /work && RUN_TARBALL=1 bash build-openbmc-arm64.sh'
# which writes kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst
# (kuiper-volume is bind-mounted at /kuiper-volume in the Kuiper build container).
#
# What this stage does, in order:
#   1. apt-install the runtime shared-library deps the stack links against
#   2. extract the stack (/usr, /etc/dbus-1) into the rootfs
#   3. drop in the ADM1600 glue (hwmon conf template + first-boot setup, the
#      inventory/association shim service, a D-Bus policy)
#   4. enable the services so on boot:
#        dbus -> ObjectMapper -> hwmon poller -> assoc shim -> bmcweb(:443)
#
# Runs from the Kuiper root (see kuiper-stages.sh: `bash -e ${script}`), so paths
# are derived from $0.

set -e

STAGE_DIR="$(dirname "$0")"
FILES="${STAGE_DIR}/files"
TARBALL="/kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst"

if [ "${CONFIG_RPI_BOOT_FILES}" != y ]; then
	echo "09.openbmc-stack: CONFIG_RPI_BOOT_FILES != y, skipping."
	exit 0
fi

if [ ! -f "${TARBALL}" ]; then
	echo "ERROR: ${TARBALL} not found." 1>&2
	echo "Build it on the host first:" 1>&2
	echo "  docker exec obmc-build bash -lc 'cd /work && RUN_TARBALL=1 bash build-openbmc-arm64.sh'" 1>&2
	exit 1
fi

echo "09.openbmc-stack: installing OpenBMC stack from ${TARBALL}"

# --- 1. Runtime dependencies (idempotent; apt skips already-present) ----------
chroot "${BUILD_DIR}" /bin/bash -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	dbus libsystemd0 \
	libtinyxml2-11 libnghttp2-14 libcap-ng0 libssl3t64 \
	libaudit1 libpam0g libcap2 libzstd1 zlib1g
EOF

# --- 2. Extract the from-source stack into the rootfs ------------------------
# zstd is not part of the Kuiper build image by default; install it on demand so
# this stage is self-contained even if the Dockerfile wasn't updated.
if ! command -v zstd >/dev/null 2>&1; then
	echo "09.openbmc-stack: zstd not found in build image, installing it..."
	apt-get update
	apt-get install -y --no-install-recommends zstd
fi
zstd -dc "${TARBALL}" | tar -C "${BUILD_DIR}" -xf -

# --- 2b. webui-vue static UI ------------------------------------------------
# bmcweb serves /usr/share/www via its static handler, but the pre-built stack
# only ships bmcweb's own assets (Redfish schemas/css) -- no index.html -> "/"
# 404s. Drop in the webui-vue bundle (built on the host; pure static JS, so it
# is architecture-independent). The bundle ships .gz-only assets on purpose:
# bmcweb serves foo.js from foo.js.gz with Content-Encoding: gzip. Hash-router
# (/#/...) means no server-side deep-link rewriting is needed.
WEBUI_DIST="/kuiper-volume/webui/dist"
if [ -f "${WEBUI_DIST}/index.html" ]; then
	echo "09.openbmc-stack: installing webui-vue into /usr/share/www"
	install -d "${BUILD_DIR}/usr/share/www"
	cp -a "${WEBUI_DIST}/." "${BUILD_DIR}/usr/share/www/"
else
	echo "WARNING: ${WEBUI_DIST}/index.html not found; web UI not installed." 1>&2
	echo "         Build it on the host: cd /tmp/webui-vue && npm ci && npm run build" 1>&2
	echo "         then copy dist -> kuiper-volume/webui/dist" 1>&2
fi

# --- 3. ADM1600 glue --------------------------------------------------------
# hwmon config template + first-boot instantiator (computes the systemd %I
# instance from the device-tree path on the running Pi)
install -Dm644 "${FILES}/adm1600-hwmon.conf" \
	"${BUILD_DIR}/usr/share/adm1600/adm1600-hwmon.conf"
install -Dm755 "${FILES}/obmc-hwmon-adm1600-setup.sh" \
	"${BUILD_DIR}/usr/bin/obmc-hwmon-adm1600-setup.sh"
install -Dm644 "${FILES}/obmc-hwmon-adm1600.service" \
	"${BUILD_DIR}/usr/lib/systemd/system/obmc-hwmon-adm1600.service"
# Generic config-driven inventory + association shim (makes bmcweb expose the
# sensors). The bmc-assoc binary ships in the stack tarball; here we install its
# systemd unit and the per-device config. Adding another hwmon device is a
# drop-in: copy a new /etc/bmc-assoc/<device>.conf and `systemctl restart
# bmc-assoc` — no recompile, no image rebuild.
install -Dm644 "${FILES}/bmc-assoc.service" \
	"${BUILD_DIR}/usr/lib/systemd/system/bmc-assoc.service"
install -Dm644 "${FILES}/bmc-assoc-adm1600.conf" \
	"${BUILD_DIR}/etc/bmc-assoc/adm1600.conf"
# minimal User.Manager provider so bmcweb can complete web UI login (role lookup)
install -Dm644 "${FILES}/adm1600-usermgr.service" \
	"${BUILD_DIR}/usr/lib/systemd/system/adm1600-usermgr.service"
# The usermgr binary is built AFTER (and separately from) the main stack tarball
# (STAGE=/kuiper-volume/openbmc/usermgr-stage), so it is NOT inside the extracted
# tarball. Install it from its stage dir here, otherwise adm1600-usermgr.service is
# enabled below with a missing binary and every web UI login fails HTTP 500.
# Rebuild it (fast) with:
#   docker exec obmc-build bash -lc 'cd /work && COMPONENTS="apt sdbusplus usermgr" \
#     STAGE=/work/kuiper-volume/openbmc/usermgr-stage bash build-openbmc-arm64.sh'
USERMGR_BIN="/kuiper-volume/openbmc/usermgr-stage/usr/bin/adm1600-usermgr"
if [ -x "${USERMGR_BIN}" ]; then
	echo "09.openbmc-stack: installing adm1600-usermgr login shim"
	install -Dm755 "${USERMGR_BIN}" "${BUILD_DIR}/usr/bin/adm1600-usermgr"
else
	echo "ERROR: ${USERMGR_BIN} not found; web UI login shim missing -> login will 500." 1>&2
	echo "       Build it with the COMPONENTS=\"apt sdbusplus usermgr\" command above." 1>&2
	exit 1
fi
# PAM service for the bmcweb web UI login. bmcweb calls pam_start("webserver",..)
# on login; without this file PAM falls back to /etc/pam.d/other (deny) and every
# login is rejected 401. (Redfish API stays auth-less via insecure-disable-auth.)
install -Dm644 "${FILES}/webserver.pam" \
	"${BUILD_DIR}/etc/pam.d/webserver"
# The 'webserver' PAM policy above gates web UI login to members of the 'redfish'
# group (pam_succeed_if user ingroup redfish). Nothing in the base Kuiper build
# creates that group, so without this a clean image rejects every web UI login
# even with correct credentials. Create it and add the default 'analog' user, so
# the image logs in out of the box as analog/analog (the usermgr shim then maps
# analog -> priv-admin via its 'sudo' membership). Add other operators with:
#   sudo usermod -aG redfish <user>
chroot "${BUILD_DIR}" /bin/bash -e <<'EOF'
groupadd -f redfish
id analog >/dev/null 2>&1 && usermod -aG redfish analog
EOF
# D-Bus policy allowing our root daemons to own xyz.openbmc_project.* names
install -Dm644 "${FILES}/openbmc-adm1600-dbus.conf" \
	"${BUILD_DIR}/usr/share/dbus-1/system.d/openbmc-adm1600.conf"

# bmcweb.service sets WorkingDirectory=/home/root
install -d "${BUILD_DIR}/home/root"

# --- 4. Refresh linker cache for the bundled libs, then enable services ------
chroot "${BUILD_DIR}" ldconfig

# Enable bmcweb.service (not just the socket): the socket alone only starts
# bmcweb on the first :443 connection, so it reads as "not running" after boot.
# Enabling the service starts it at boot; systemd still hands it the fd from
# bmcweb.socket (socket's Service=bmcweb.service), so there is no port clash.
chroot "${BUILD_DIR}" systemctl enable \
	xyz.openbmc_project.ObjectMapper.service \
	obmc-hwmon-adm1600.service \
	bmc-assoc.service \
	adm1600-usermgr.service \
	bmcweb.service \
	bmcweb.socket

echo "09.openbmc-stack: done."
echo "  After boot (ADM1600 present on I2C): "
echo "    curl -k https://<pi-ip>/redfish/v1/Chassis/adm1600/Sensors"
