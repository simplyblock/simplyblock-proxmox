#!/usr/bin/env bash
# Rebuilds the indexes of the Debian repository in the given directory from the
# packages in its pool/ and signs them with the given GPG key.
#
# Usage: build-debian-repository.sh <repository-dir> <gpg-key-id>
set -euo pipefail

REPOSITORY_DIR=$1
SIGNING_KEY=$2

do_hash() {
    HASH_NAME=$1
    HASH_CMD=$2
    echo "${HASH_NAME}:"
    # The Release file and its signatures are not part of the index.
    find . -type f ! -name Release ! -name Release.gpg ! -name InRelease | cut -c3- | sort | while read -r f; do
        echo " $(${HASH_CMD} "${f}" | cut -d" " -f1) $(wc -c < "${f}") ${f}"
    done
}

cd "${REPOSITORY_DIR}"
# Every version in the pool is listed, so users can pin or roll back to any release.
echo "Scanning pool..."
for arch in all amd64 arm64; do
    mkdir -p "dists/stable/main/binary-${arch}"
    dpkg-scanpackages --multiversion --arch "${arch}" pool/ > "dists/stable/main/binary-${arch}/Packages"
    gzip -9 -n < "dists/stable/main/binary-${arch}/Packages" > "dists/stable/main/binary-${arch}/Packages.gz"
done

cd dists/stable
echo "Creating Release file..."
cat << 'EOF' > Release
Origin: Simplyblock Debian Repository
Label: Simplyblock
Suite: stable
Codename: stable
Version: 1.0
Architectures: amd64 arm64
Components: main
Description: Simplyblock packages, including the simplyblock storage plugin for Proxmox VE
EOF
echo "Date: $(date -Ru)" >> Release

do_hash "MD5Sum" "md5sum" >> Release
do_hash "SHA1" "sha1sum" >> Release
do_hash "SHA256" "sha256sum" >> Release

echo "Signing Release file..."
gpg --batch --yes --local-user "${SIGNING_KEY}" --armor --detach-sign --output Release.gpg Release
gpg --batch --yes --local-user "${SIGNING_KEY}" --clearsign --output InRelease Release
