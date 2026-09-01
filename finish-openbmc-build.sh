#!/bin/bash -e
# SPDX-License-Identifier: BSD-3-Clause
#
# Resume an interrupted Kuiper build from the committed rootfs image
# (kuiper-salvage:tmp), picking up right after the point where
# stages/07.extra-tweaks/09.openbmc-stack/run.sh failed on `zstd: command
# not found`. Runs the remaining stages only, so debootstrap + all the ADI
# tooling (already baked into the 2.8G rootfs) is NOT redone.
#
# Meant to run INSIDE a container started from kuiper-salvage:tmp with the same
# flags build-docker.sh uses (see the docker run one-liner in the chat / README).

# errexit here on its own: the docker CMD invokes this as `bash <script>`, which
# makes the `#!/bin/bash -e` shebang a no-op (the shebang is only honoured when
# the file is executed directly). Set the flags explicitly so a stage failure
# actually stops us instead of being silently reported as success.
set -eo pipefail

set -a
cd /
source config                 # TARGET_ARCHITECTURE, CONFIG_RPI_BOOT_FILES, ...
set +a
export BUILD_DIR="${TARGET_ARCHITECTURE}_rootfs"

# The export-image stage needs env that the normal orchestrator (kuiper-stages.sh)
# exports but that we bypass here. Reproduce the ones the remaining stages read.
# IMG_FILE was the missing one — its absence made `truncate ... ''` fail and the
# whole image build silently produce nothing.
export IMG_FILE="image_$(date +%Y-%m-%d)-ADI-Kuiper-Linux-${TARGET_ARCHITECTURE}.img"
export NUM_JOBS="${NUM_JOBS:-$(nproc)}"
export HOSTNAME="${HOSTNAME:-analog}"
export DEBIAN_SNAPSHOT="${DEBIAN_SNAPSHOT:-}"
export EXPORT_SOURCES="${EXPORT_SOURCES:-n}"
export ADI_EVAL_BOARD="${ADI_EVAL_BOARD:-}"
export CARRIER="${CARRIER:-}"

# The old image predates the Dockerfile fix, so make sure the decompressor the
# openbmc stage needs is present before we re-run it.
if ! command -v zstd >/dev/null 2>&1; then
	echo ">>> installing zstd into the build image"
	apt-get update
	apt-get install -y --no-install-recommends zstd
fi

STAGES="
stages/07.extra-tweaks/09.openbmc-stack/run.sh
stages/08.export-stage/01.extend-rootfs/run.sh
stages/08.export-stage/02.export-sources/run.sh
stages/08.export-stage/03.generate-license/run.sh
stages/08.export-stage/04.export-image/run.sh
"

for s in ${STAGES}; do
	echo "==================== resume stage: ${s} ===================="
	if ! bash -e "${s}"; then
		echo "SALVAGE-BUILD-FAILED at ${s}" >&2
		exit 1
	fi
	echo "-------------------- done: ${s} --------------------"
done

# Prove the image actually exists before declaring victory (the previous run
# reported success while producing nothing).
IMG_ZIP="/kuiper-volume/image_$(date +%Y-%m-%d)-ADI-Kuiper-Linux-${TARGET_ARCHITECTURE}.zip"
if [ ! -s "${IMG_ZIP}" ]; then
	echo "SALVAGE-BUILD-FAILED: expected ${IMG_ZIP} was not produced" >&2
	exit 1
fi
echo "SALVAGE-BUILD-DONE: $(ls -l "${IMG_ZIP}")"
