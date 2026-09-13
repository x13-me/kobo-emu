#!/usr/bin/env bash
# Step1b launcher: rect-correspondence run on :1248. Timeboxed, /tmp only.
set -euo pipefail
cd /home/user/kobo-emu
VERSION="4.38.23684"
ROOT="build/rootfs-$VERSION"
PORT="1248"

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
print("step1b: staged fb backing + empty touch/button FIFOs")
PYEOF

FAKEBIN_LOG="/tmp/kobo-step1/fakebin-step1b.log"
: > "$FAKEBIN_LOG"
rm -f /tmp/kobo-step1/qimage-su2b.bin /tmp/kobo-step1/gdb-step1b.log /tmp/kobo-step1/qemu-step1b.log

QEMU_ARM="$(command -v qemu-arm)"
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
  >/tmp/kobo-step1/qemu-step1b.log 2>&1 &
QEMU_PID=$!
echo "step1b: qemu pid=$QEMU_PID port=$PORT"
sleep 2
timeout 75 gdb -batch -x /tmp/kobo-step1/gdb-step1b.txt > /tmp/kobo-step1/gdb-step1b.log 2>&1 || GDB_RC=$?
GDB_RC=${GDB_RC:-0}
echo "step1b: gdb rc=$GDB_RC"
wait $QEMU_PID || QEMU_RC=$?
QEMU_RC=${QEMU_RC:-0}
echo "step1b: qemu rc=$QEMU_RC"
ls -la /tmp/kobo-step1/qimage-su2b.bin 2>&1 || true
