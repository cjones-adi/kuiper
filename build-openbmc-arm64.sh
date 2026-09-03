#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the minimal OpenBMC D-Bus -> Redfish stack from source for arm64 Debian
# Trixie, pinned to the same commits OpenBMC tracks (see openbmc-stack-build-effort
# memory / meta-phosphor recipes). Produces a relocatable tarball that the Kuiper
# stage 07.extra-tweaks/09.openbmc-stack extracts into the rootfs.
#
# WHERE THIS RUNS: an arm64 Debian Trixie environment — either
#   (a) a standalone container for fast iteration:
#         docker run --rm -it -v "$PWD":/work -w /work \
#           --platform linux/arm64 debian:trixie bash build-openbmc-arm64.sh
#   (b) the Kuiper build chroot (same script, invoked by the stage).
#
# OUTPUT: $STAGE (DESTDIR) with /usr/... artifacts, tarred to
#         kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst (when RUN_TARBALL=1).
#
# Iterate one component at a time with: COMPONENTS="stdplus sdbusplus" ...
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-/usr}"
STAGE="${STAGE:-/opt/obmc-stage}"          # DESTDIR for the final tarball
SRCDIR="${SRCDIR:-/usr/local/src/obmc}"
JOBS="${JOBS:-$(nproc)}"
OUT_TARBALL="${OUT_TARBALL:-/work/kuiper-volume/openbmc/openbmc-stack-arm64.tar.zst}"
RUN_TARBALL="${RUN_TARBALL:-0}"

# Pinned upstream commits (OpenBMC master snapshot, from meta-phosphor recipes)
FUNCTION2_REV="a354bd093d2b6e50c9325dbce84d20b4e77aabc6"
STDEXEC_REV="250f35737790392d666fd157e0af9be16d0c789f"
STDPLUS_REV="38af2d8b75cf158f61934bb010673185bfca6117"
SDEVENTPLUS_REV="c3fb820143af91bcaf8da9745c631c12cecf3353"
GPIOPLUS_REV="f8dfbb82b6f6cbdc1cd53490dd0ad96b74ab653c"
SDBUSPLUS_REV="663b7b73184a8687c5c9add63cb58e06d3073f01"
PDI_REV="3d500d70755659e8a107c901201f874bfea4d4ba"          # phosphor-dbus-interfaces
LOGGING_REV="feeb108287a095108283f3978dfa608502d55494"      # phosphor-logging
OBJMGR_REV="4a46c7116ce701191e7ed4f7903c4467b448e4c0"       # phosphor-objmgr
HWMON_REV="dd7b388e4bee2e76f2a3aa9a3bc4ba27add0b090"        # phosphor-hwmon
BMCWEB_REV="b84653e71c342f965da5a631b8d2a4766a1606a7"

# Which components to build (space-separated); default = all, in order.
COMPONENTS="${COMPONENTS:-apt function2 stdexec stdplus sdeventplus gpioplus sdbusplus pdi logging objmgr hwmon bmcweb assoc usermgr}"

# Generic config-driven association shim source (compiled by the 'assoc'
# component). Device-agnostic: reads /etc/bmc-assoc/*.conf at runtime, so a new
# device needs a drop-in .conf, not a recompile. Lives in the Kuiper stage dir
# (mounted at /work in the build container).
SHIM_SRC="${SHIM_SRC:-/work/stages/07.extra-tweaks/09.openbmc-stack/files/bmc-assoc.cpp}"

GH="https://github.com"
log() { echo -e "\n\033[1;35m=== $* ===\033[0m"; }

# clone_pin <url> <rev> <dirname>
clone_pin() {
	local url="$1" rev="$2" dir="$3"
	mkdir -p "$SRCDIR"; cd "$SRCDIR"
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	fi
	git -C "$dir" fetch -q --depth 1 origin "$rev" || git -C "$dir" fetch -q origin
	git -C "$dir" checkout -q "$rev"
	# init any submodules (function2 etc. are gitsm)
	git -C "$dir" submodule update -q --init --recursive --depth 1 || true
	cd "$dir"
}

# meson_install <srcdir> [meson opts...]
meson_install() {
	local dir="$1"; shift
	cd "$SRCDIR/$dir"
	rm -rf builddir
	meson setup builddir --prefix="$PREFIX" --buildtype=minsize \
		--wrap-mode=default "$@"
	meson compile -C builddir -j "$JOBS"
	DESTDIR="$STAGE" meson install -C builddir --no-rebuild
	# Also install into the live prefix so later components can find headers/libs
	meson install -C builddir --no-rebuild
	ldconfig || true
}

want() { case " $COMPONENTS " in *" $1 "*) return 0;; *) return 1;; esac; }

# ---------------------------------------------------------------------------
# 0. Build + codegen dependencies from Debian
# ---------------------------------------------------------------------------
if want apt; then
	log "apt: build dependencies"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends \
		build-essential g++ gcc pkg-config git ca-certificates \
		meson ninja-build cmake \
		python3 python3-pip python3-setuptools python3-wheel \
		python3-yaml python3-mako python3-jsonschema python3-inflection \
		libsystemd-dev systemd systemd-dev libssl-dev libpam0g-dev zlib1g-dev \
		libnghttp2-dev libtinyxml2-dev nlohmann-json3-dev libdbus-1-dev \
		libboost-all-dev libfmt-dev liburing-dev libcli11-dev \
		libgtest-dev libgmock-dev libcereal-dev zstd
	# inflection sometimes missing from apt on Trixie; ensure via pip
	python3 -c 'import inflection' 2>/dev/null || \
		pip3 install --break-system-packages inflection
fi

mkdir -p "$STAGE" "$SRCDIR"

# ---------------------------------------------------------------------------
# 1. Header-only leaves
# ---------------------------------------------------------------------------
if want function2; then
	log "function2 (header-only) — build-time only, headers -> live prefix"
	clone_pin "$GH/Naios/function2" "$FUNCTION2_REV" function2
	# function2 is CMake/header-only (no meson.build). Just place the header
	# where consuming meson projects find it. Not needed at runtime.
	install -Dm644 "$SRCDIR/function2/include/function2/function2.hpp" \
		"$PREFIX/include/function2/function2.hpp"
fi

if want stdexec; then
	log "stdexec (NVIDIA, header-only) — build-time only, headers -> live prefix"
	clone_pin "$GH/NVIDIA/stdexec" "$STDEXEC_REV" stdexec
	# Running stdexec's cmake pulls rapids-cmake/CPM via FetchContent (slow,
	# network-bound) purely to stage headers. Copy the include/ tree directly.
	# Header-only: needed only to BUILD sdbusplus/bmcweb, never at runtime.
	cp -a "$SRCDIR/stdexec/include/." "$PREFIX/include/"
fi

# ---------------------------------------------------------------------------
# 2. OpenBMC utility libs
# ---------------------------------------------------------------------------
want stdplus     && { log "stdplus";     clone_pin "$GH/openbmc/stdplus"     "$STDPLUS_REV" stdplus;         meson_install stdplus     -Dexamples=false -Dtests=disabled -Dgtest=disabled; }
want sdeventplus && { log "sdeventplus"; clone_pin "$GH/openbmc/sdeventplus" "$SDEVENTPLUS_REV" sdeventplus; meson_install sdeventplus -Dexamples=false -Dtests=disabled; }
want gpioplus    && { log "gpioplus";    clone_pin "$GH/openbmc/gpioplus"    "$GPIOPLUS_REV" gpioplus;       meson_install gpioplus    -Dexamples=false -Dtests=disabled; }

# ---------------------------------------------------------------------------
# 3. sdbusplus (+ sdbus++ codegen tool) -> gates pdi/logging
# ---------------------------------------------------------------------------
if want sdbusplus; then
	log "sdbusplus (lib + sdbus++ codegen)"
	clone_pin "$GH/openbmc/sdbusplus" "$SDBUSPLUS_REV" sdbusplus
	# codegen tool onto PATH (PEP668 -> break-system-packages)
	pip3 install --break-system-packages "$SRCDIR/sdbusplus/tools"
	meson_install sdbusplus -Dexamples=disabled -Dtests=disabled
fi

# ---------------------------------------------------------------------------
# 4. phosphor-dbus-interfaces (needs sdbus++), then phosphor-logging
# ---------------------------------------------------------------------------
want pdi     && { log "phosphor-dbus-interfaces"; clone_pin "$GH/openbmc/phosphor-dbus-interfaces" "$PDI_REV" phosphor-dbus-interfaces; meson_install phosphor-dbus-interfaces; }
want logging && { log "phosphor-logging";         clone_pin "$GH/openbmc/phosphor-logging"         "$LOGGING_REV" phosphor-logging;   meson_install phosphor-logging -Dtests=disabled; }

# ---------------------------------------------------------------------------
# 5. Daemons
# ---------------------------------------------------------------------------
want objmgr && { log "phosphor-objmgr (ObjectMapper)"; clone_pin "$GH/openbmc/phosphor-objmgr" "$OBJMGR_REV" phosphor-objmgr; meson_install phosphor-objmgr -Dtests=disabled; }
want hwmon  && { log "phosphor-hwmon";                 clone_pin "$GH/openbmc/phosphor-hwmon"  "$HWMON_REV" phosphor-hwmon;   meson_install phosphor-hwmon  -Dtests=disabled; }
if want bmcweb; then
	log "bmcweb (Redfish/web server)"
	clone_pin "$GH/openbmc/bmcweb" "$BMCWEB_REV" bmcweb
	# The boost-1.89 wrap bmcweb pulls trips gcc-14's -Werror=type-limits inside
	# boost's own process sources (cmd.cpp/env.cpp). bmcweb builds with
	# warnings-as-errors and meson propagates that into the wrap. Demote errors
	# for the whole build via env flags (meson appends CFLAGS/CXXFLAGS captured at
	# setup to every compile, subprojects included).
	# insecure-disable-auth: this is a dev-bench bring-up image — serve Redfish
	# without PAM/user-manager auth so sensors are viewable via `curl -k` out of
	# the box. TLS stays on (bmcweb self-signs on first boot). Revisit before any
	# non-bench use. See openbmc-stack memory.
	CFLAGS="${CFLAGS:-} -Wno-error" CXXFLAGS="${CXXFLAGS:-} -Wno-error" \
		meson_install bmcweb -Dtests=disabled -Dbmcweb-logging=enabled \
			-Dinsecure-disable-auth=enabled
fi

# ---------------------------------------------------------------------------
# 5b. ADM1600 inventory + association shim (glue so bmcweb sees the sensors)
# ---------------------------------------------------------------------------
if want assoc; then
	log "bmc-assoc (generic config-driven inventory + association shim)"
	[ -r "$SHIM_SRC" ] || { echo "ERROR: shim source not found: $SHIM_SRC" >&2; exit 1; }
	g++ -std=c++23 -O2 "$SHIM_SRC" -o /tmp/bmc-assoc \
		$(pkg-config --cflags --libs sdbusplus)
	install -Dm755 /tmp/bmc-assoc "$STAGE/usr/bin/bmc-assoc"
	install -Dm755 /tmp/bmc-assoc "$PREFIX/bin/bmc-assoc"
fi

# ---------------------------------------------------------------------------
# 5c. Minimal User.Manager provider (so bmcweb can complete web UI login)
# ---------------------------------------------------------------------------
if want usermgr; then
	log "adm1600-usermgr (User.Manager provider for bmcweb login)"
	USERMGR_SRC="${USERMGR_SRC:-/work/stages/07.extra-tweaks/09.openbmc-stack/files/adm1600-usermgr.cpp}"
	[ -r "$USERMGR_SRC" ] || { echo "ERROR: usermgr source not found: $USERMGR_SRC" >&2; exit 1; }
	g++ -std=c++23 -O2 "$USERMGR_SRC" -o /tmp/adm1600-usermgr \
		$(pkg-config --cflags --libs sdbusplus)
	install -Dm755 /tmp/adm1600-usermgr "$STAGE/usr/bin/adm1600-usermgr"
	install -Dm755 /tmp/adm1600-usermgr "$PREFIX/bin/adm1600-usermgr"
fi

# ---------------------------------------------------------------------------
# 6. Package the staged tree
# ---------------------------------------------------------------------------
if [ "$RUN_TARBALL" = 1 ]; then
	log "tarball -> $OUT_TARBALL"
	# Drop build-only artifacts so the runtime tree stays lean.
	rm -rf "$STAGE/usr/include" "$STAGE/usr/share/pkgconfig" 2>/dev/null || true
	rm -rf "$STAGE"/usr/lib/*/pkgconfig "$STAGE"/usr/lib/*/cmake 2>/dev/null || true
	find "$STAGE" -name '*.a' -delete 2>/dev/null || true
	# Strip ELF binaries/libs (ignore scripts/failures).
	find "$STAGE" -type f \( -name '*.so' -o -name '*.so.*' \) \
		-exec strip --strip-unneeded {} + 2>/dev/null || true
	for b in mapperx phosphor-hwmon-readd bmcweb bmc-assoc adm1600-usermgr \
		mapper phosphor-log-manager; do
		strip --strip-unneeded "$(find "$STAGE" -type f -name "$b" | head -1)" 2>/dev/null || true
	done
	mkdir -p "$(dirname "$OUT_TARBALL")"
	tar -C "$STAGE" -c . | zstd -19 -T0 -o "$OUT_TARBALL"
	echo "Wrote $(du -sh "$OUT_TARBALL" | cut -f1) : $OUT_TARBALL"
fi

log "DONE. Built: $COMPONENTS"
echo "Staged artifacts under: $STAGE"
