#!/bin/bash
# Stage the ADM1600 arm64 kernel artifacts into kuiper-volume/ so the
# 06.boot-partition/03.adm1600-kernel Kuiper stage can install them into the
# rootfs at build time.
#
# Run on the HOST (no sudo needed) BEFORE `sudo ./build-docker.sh`.
# Re-run whenever the kernel is rebuilt.
#
#   KSRC=/path/to/linux ./stage-adm1600-kernel.sh   (defaults to ~/innersource/linux)
set -euo pipefail

KSRC="${KSRC:-$HOME/innersource/linux}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEST="$HERE/kuiper-volume/adm1600-kernel"
KREL="$(make -C "$KSRC" -s kernelrelease | tail -1)"

echo "Kernel source : $KSRC"
echo "Kernel release: $KREL"
echo "Staging into  : $DEST"

rm -rf "$DEST"
mkdir -p "$DEST/boot/overlays" "$DEST/lib"

# 1) Kernel image — 64-bit RPi firmware loads kernel8.img by default
install -m644 "$KSRC/arch/arm64/boot/Image" "$DEST/boot/kernel8.img"

# 2) Device trees for Pi 4 / Pi 400 (bcm2711)
install -m644 "$KSRC/arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb" "$DEST/boot/"
install -m644 "$KSRC/arch/arm64/boot/dts/broadcom/bcm2711-rpi-400.dtb" "$DEST/boot/" || true

# 3) Overlays (incl. adm1600.dtbo) + overlay map
cp "$KSRC"/arch/arm64/boot/dts/overlays/*.dtbo "$DEST/boot/overlays/"
[ -f "$KSRC/arch/arm64/boot/dts/overlays/overlay_map.dtb" ] && \
  cp "$KSRC/arch/arm64/boot/dts/overlays/overlay_map.dtb" "$DEST/boot/overlays/"

# 4) Kernel modules tree -> lib/modules/$KREL
# (no INSTALL_MOD_STRIP: host 'strip' is x86 and can't process arm64 .ko;
#  set STRIP=aarch64-linux-gnu-strip + INSTALL_MOD_STRIP=1 if you have it and
#  want smaller modules.)
make -C "$KSRC" -s modules_install INSTALL_MOD_PATH="$DEST"
# Drop dangling host-path build/source symlinks (invalid on the target)
rm -f "$DEST/lib/modules/$KREL/build" "$DEST/lib/modules/$KREL/source"

echo "$KREL" > "$DEST/KERNEL_RELEASE"
echo "Done. Staged $(du -sh "$DEST" | cut -f1) into $DEST"
