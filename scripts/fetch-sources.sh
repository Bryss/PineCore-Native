#!/bin/bash
# Fetch every third-party source at a pinned revision into third_party/ and
# apply the Pager patch to meshcore-linux. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p third_party

fetch() {  # dir url revision [--recurse]
  local dir=$1 url=$2 rev=$3
  if [ ! -d "third_party/$dir/.git" ]; then
    git clone -q "$url" "third_party/$dir"
  fi
  if [ "$(git -C "third_party/$dir" rev-parse HEAD)" != "$(git -C "third_party/$dir" rev-parse "$rev^{commit}" 2>/dev/null)" ]; then
    git -C "third_party/$dir" fetch -q --tags origin
    git -C "third_party/$dir" -c advice.detachedHead=false checkout -q "$rev"
  fi
  if [ "${4:-}" = --recurse ]; then git -C "third_party/$dir" submodule -q update --init; fi
}

# MeshCore Linux port (l5yth/meshcore-linux, branch l5y-linux-companion)
fetch meshcore    https://github.com/l5yth/meshcore-linux.git 32e9f953584db9468b8db89780208979cdaea8c6
fetch ardulinux   https://github.com/l5yth/ardulinux.git       v0.2.3 --recurse
fetch RadioLib    https://github.com/jgromes/RadioLib.git      6d8934836678d8894e3d556550475b37dce3e2b6
fetch arduinolibs https://github.com/rweather/arduinolibs.git  37a76b8f
fetch CayenneLPP  https://github.com/ElectronicCats/CayenneLPP.git 1.6.1
fetch base64      https://github.com/Densaugeo/base64_arduino.git 574949c
fetch ArduinoJson https://github.com/bblanchon/ArduinoJson.git v7.4.2
fetch RTClib      https://github.com/adafruit/RTClib.git 2.1.4
fetch BusIO       https://github.com/adafruit/Adafruit_BusIO.git 1.17.0
fetch RV3028      https://github.com/melopero/Melopero_RV-3028_Arduino_Library.git 1.1.0

LIBUSB=third_party/libusb-1.0.27.tar.bz2
LIBUSB_SHA256=ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575
[ -f "$LIBUSB" ] || curl -sSL -o "$LIBUSB" https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2
echo "$LIBUSB_SHA256  $LIBUSB" | shasum -a 256 -c - >/dev/null || { echo "libusb checksum mismatch" >&2; exit 1; }

PATCH="$PWD/patches/meshcore-pager-ch341.patch"
if git -C third_party/meshcore apply --reverse --check "$PATCH" 2>/dev/null; then
  :  # already applied
else
  git -C third_party/meshcore apply "$PATCH"
fi
