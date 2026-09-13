#!/bin/sh
# Fresh strace nickel run: same staging/env as run-usermode.sh --mode nickel, plus -strace.
set -u
ROOT=build/rootfs-4.38.23684
FAKEBIN_LOG="$PWD/artifacts/fakebin-strace6-nickel.log"
: > "$FAKEBIN_LOG"
QEMU_ARM="$(command -v qemu-arm)"
echo "using $QEMU_ARM"
# shellcheck disable=SC2086
env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  timeout 75 "$QEMU_ARM" -L "$ROOT" -strace \
  -E "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/Kobo:$PWD/scripts/fakebin" \
  -E "FAKEBIN_DIR=$PWD/scripts/fakebin" \
  -E "FAKEBIN_LOG_PATH=$FAKEBIN_LOG" \
  -E LC_ALL=C -E LANG=C \
  -E LD_LIBRARY_PATH=/usr/local/Kobo:/usr/local/Qt-5.2.1-arm/lib \
  -E LD_PRELOAD=/kobo-emu/libkobofb.so \
  -E KOBO_SHIM_LOG=/tmp/kobo-shim.log \
  -E PLATFORM=mx50-ntx -E CPU=mx50 -E PRODUCT=trilogy \
  -E INTERFACE=eth0 -E WIFI_MODULE=dhd \
  -E NICKEL_HOME=/mnt/onboard/.kobo \
  "$ROOT/usr/local/Kobo/nickel" -platform kobo -skipFontLoad \
  >artifacts/nickel-strace6-stdout.log 2>artifacts/nickel-strace6.log
echo "rc=$?"
