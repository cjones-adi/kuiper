#!/bin/bash -e
# SPDX-License-Identifier: BSD-3-Clause
#
# kuiper2.0 - Embedded Linux for Analog Devices Products
#
# Copyright (c) 2024 Analog Devices, Inc.
# Author: Larisa Radu <larisa.radu@analog.com>

source config

DEBIAN_VERSION=${DEBIAN_VERSION:-trixie}
BASE_IMAGE="debian:${DEBIAN_VERSION}"
IMAGE_NAME="debian_${DEBIAN_VERSION}_rootfs"
CONTAINER_NAME=${CONTAINER_NAME:-"${IMAGE_NAME}_container"}
PRESERVE_CONTAINER=${PRESERVE_CONTAINER:-n}

cleanup() {
	docker rm -fv ${CONTAINER_NAME}
	exit 1
}

# Remove container if build was interrupted or cancelled
trap cleanup SIGINT SIGTERM

# Check if the script is run as root
if [ "$(id -u)" != "0" ] ; then
	echo "This script must be run as root"
	exit 1
fi

# Check if Debian version is supported
if [[ ! ${DEBIAN_VERSION} = bookworm && ! ${DEBIAN_VERSION} = bullseye && ! ${DEBIAN_VERSION} = trixie ]]; then
	echo "Unsupported Debian version ${DEBIAN_VERSION}"
	exit 1
fi

# Register qemu-user-static so arm64 binaries run inside the chroot via
# binfmt_misc. On a non-arm host this is mandatory: without an active
# qemu-aarch64 handler, every arm64 maintainer script in the rootfs dies with
# "Exec format error" (and, because the failure surfaces ~6 stages later at
# 06.boot-partition, it looks like an unrelated dpkg bug). These registrations
# do NOT survive a WSL2 / Docker VM restart, so (re-)register every run AND
# verify, since the registration container's failures are otherwise silent.
host_arch="$(uname -m)"
if [[ "${host_arch}" != aarch64 && "${host_arch}" != arm* ]]; then
	if ! docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; then
		echo "ERROR: failed to register qemu-user-static binfmt handlers" >&2
		exit 1
	fi
	if ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
		echo "ERROR: qemu-aarch64 binfmt handler is not active after registration." >&2
		echo "       arm64 chroot operations would fail with 'Exec format error'." >&2
		echo "       Try: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes" >&2
		exit 1
	fi
fi

# Build docker image
docker build --build-arg BASE_IMAGE="${BASE_IMAGE}" -t ${IMAGE_NAME} .

# Run docker container
# -t: pseudo-TTY allowing interaction with container's shell
# --privileged: elevanted privileges required by the chroot command
# -v: mounts volumes allowing the container to access files on the host or work with kernel modules
# -e: sets environment variables
# Inside the container kuiper-stages.sh will run building the Kuiper image
docker run -t --privileged \
			-v /dev:/dev \
			-v /lib/modules:/lib/modules \
			-v ./kuiper-volume:/kuiper-volume \
			-e "DEBIAN_VERSION="${DEBIAN_VERSION}"" \
			--name ${CONTAINER_NAME} ${IMAGE_NAME} \
			/bin/bash -o pipefail -c "bash kuiper-stages.sh"

if [ $PRESERVE_CONTAINER = n ]; then
	# Remove image, container and corresponding volume
	docker rm -v ${CONTAINER_NAME}
fi

docker image rm -f ${IMAGE_NAME}

# Detach loops
LOOP_DEVICES=$(losetup --list | grep "$(basename "ADI-Kuiper-Linux.*.img")" | cut -f1 -d' ')
for LOOP_DEV in ${LOOP_DEVICES}; do
	losetup -d ${LOOP_DEV}
done


# Save info about kuiper repository in log file
echo -e "\nADI Kuiper Linux:" >> "kuiper-volume/ADI_repos_git_info.txt"
echo "Repo   : $(git remote get-url origin)" >> "kuiper-volume/ADI_repos_git_info.txt"
echo "Branch : $(git branch | cut -d' ' -f2)" >> "kuiper-volume/ADI_repos_git_info.txt"
echo -e "Git_sha: $(git rev-parse --short HEAD)\n\n" >> "kuiper-volume/ADI_repos_git_info.txt"
