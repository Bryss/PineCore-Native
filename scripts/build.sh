#!/bin/bash
# Build build/meshcored for the Pineapple Pager inside the official OpenWrt
# 24.10.1 SDK image (ramips/mt76x8 = mipsel_24kc musl). Runs on any Docker host;
# on Apple Silicon the amd64 image runs under emulation.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_IMAGE='openwrt/sdk:ramips-mt76x8-v24.10.1'
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

scripts/fetch-sources.sh

docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work -e VERSION="$VERSION" "$SDK_IMAGE" bash -c '
  set -euo pipefail
  export PATH="$(echo /builder/staging_dir/toolchain-*/bin):$PATH"
  export STAGING_DIR=/builder/staging_dir
  if [ ! -f build/libusb/lib/libusb-1.0.a ]; then
    rm -rf build/libusb-src && mkdir -p build/libusb-src
    tar xjf third_party/libusb-1.0.27.tar.bz2 -C build/libusb-src --strip-components=1
    (cd build/libusb-src && ./configure -q --host=mipsel-openwrt-linux-musl --disable-udev \
       --enable-static --disable-shared --prefix=/work/build/libusb && make -s -j"$(nproc)" install)
  fi
  make -j"$(nproc)" VERSION="$VERSION"
  mipsel-openwrt-linux-musl-readelf -h build/meshcored | grep -E "Class|Machine|Flags"
'
cp build/meshcored payload/MeshCoreNative/meshcored
(cd payload/MeshCoreNative && shasum -a 256 meshcored meshcored.ini > SHA256SUMS)
ls -la payload/MeshCoreNative
