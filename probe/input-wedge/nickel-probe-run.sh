#!/bin/sh
# Probe run: same staging/env as nickel-strace6, plus a background SYN-stream
# into the BUTTON backing (event0) to keep the main thread's evdev drain
# supplied. No tree changes: injector + logs live in /tmp and artifacts/.
set -u
ROOT=build/rootfs-4.38.23684
FAKEBIN_LOG="$PWD/artifacts/fakebin-probe-nickel.log"
: > "$FAKEBIN_LOG"
QEMU_ARM="$(command -v qemu-arm)"
echo "using $QEMU_ARM"
python3 /tmp/opencode/button-stream.py &
INJ_PID=$!
echo "injector pid=$INJ_PID"
# shellcheck disable=SC2086
env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  timeout 70 "$QEMU_ARM" -L "$ROOT" -strace \
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
  >artifacts/nickel-probe-stdout.log 2>artifacts/nickel-probe.log
echo "rc=$?"
kill "$INJ_PID" 2>/dev/null
wait 2>/dev/null
echo "injector stopped"
