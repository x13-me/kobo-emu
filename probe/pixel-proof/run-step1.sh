#!/usr/bin/env bash
# Step1 launcher: qemu-arm -g on :1245 + gdb batch dump. All scratch in /tmp.
# No tree changes. Both sides wrapped in timeout (anti-hang).
set -euo pipefail
cd /home/user/kobo-emu
VERSION="4.38.23684"
ROOT="build/rootfs-$VERSION"
PORT="1247"

python3 - "$ROOT" <<'PYEOF'
import os, sys
root = sys.argv[1]
tmp = os.path.join(root, "tmp")
with open(os.path.join(tmp, "kobo-fb0.bin"), "wb") as h:
    h.truncate(800 * 600 * 2)
open(os.path.join(tmp, "kobo-shim.log"), "w").close()
for name in ("kobo-touch0.bin", "kobo-button0.bin"):
    p = os.path.join(tmp, name)
    try:
        os.remove(p)
    except OSError:
        pass
    os.mkfifo(p, 0o644)
print("step1: staged fb backing + empty touch/button FIFOs")
PYEOF

FAKEBIN_LOG="/tmp/kobo-step1/fakebin-step1.log"
: > "$FAKEBIN_LOG"
rm -f /tmp/kobo-step1/qimage-su2.bin /tmp/kobo-step1/gdb-step1.log /tmp/kobo-step1/qemu-step1.log

QEMU_ARM="$(command -v qemu-arm)"
# Guest: background + timeout 90s (hard cap per anti-hang rules).
env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  timeout 90 "$QEMU_ARM" -g "$PORT" -L "$ROOT" \
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
  -E KOBO_TOUCH_FIFO=1 \
  "$ROOT/usr/local/Kobo/nickel" -platform kobo -skipFontLoad \
  >/tmp/kobo-step1/qemu-step1.log 2>&1 &
QEMU_PID=$!
echo "step1: qemu pid=$QEMU_PID port=$PORT"

# qemu-arm -g waits for the gdb connection before running the guest, so no
# readiness probe is needed (a raw TCP probe corrupts the RSP stream).
# Fixed sleep, then gdb batch (cap 75s).
sleep 2
timeout 75 gdb -batch -x /tmp/kobo-step1/gdb-step1.txt > /tmp/kobo-step1/gdb-step1.log 2>&1 || GDB_RC=$?
GDB_RC=${GDB_RC:-0}
echo "step1: gdb rc=$GDB_RC"
# Guest may still run after gdb quit/disconnect; reap via wait (timeout kills it at 90s).
wait $QEMU_PID || QEMU_RC=$?
QEMU_RC=${QEMU_RC:-0}
echo "step1: qemu rc=$QEMU_RC (124 = timeout-killed, expected if guest idled)"
ls -la /tmp/kobo-step1/ || true
