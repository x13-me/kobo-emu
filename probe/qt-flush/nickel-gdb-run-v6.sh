#!/usr/bin/env bash
# Phase 2.4 gdb probe launcher for v6 survey — mirrors nickel-gdb-run.sh
# staging/env on PORT 1236, plus KOBO_DEBUG_FLUSHES=1. No tree changes.
set -euo pipefail
cd /home/user/kobo-emu
VERSION="4.38.23684"
ROOT="build/rootfs-$VERSION"
PORT="${1:-1236}"

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
print("gdb-v6-probe: staged fb backing + empty touch/button FIFOs")
PYEOF

FAKEBIN_LOG="/tmp/opencode/fakebin-gdb-v6.log"
: > "$FAKEBIN_LOG"
QEMU_ARM="$(command -v qemu-arm)"
exec env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  "$QEMU_ARM" -g "$PORT" -L "$ROOT" \
  -E "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/Kobo:$PWD/scripts/fakebin" \
  -E "FAKEBIN_DIR=$PWD/scripts/fakebin" \
  -E "FAKEBIN_LOG_PATH=$FAKEBIN_LOG" \
  -E LC_ALL=C -E LANG=C \
  -E LD_LIBRARY_PATH=/usr/local/Kobo:/usr/local/Qt-5.2.1-arm/lib \
  -E LD_PRELOAD=/kobo-emu/libkobofb.so \
  -E KOBO_SHIM_LOG=/tmp/kobo-shim.log \
  -E KOBO_DEBUG_FLUSHES=1 \
  -E PLATFORM=mx50-ntx -E CPU=mx50 -E PRODUCT=trilogy \
  -E INTERFACE=eth0 -E WIFI_MODULE=dhd \
  -E NICKEL_HOME=/mnt/onboard/.kobo \
  -E KOBO_TOUCH_FIFO=1 \
  "$ROOT/usr/local/Kobo/nickel" -platform kobo -skipFontLoad \
  >/tmp/opencode/nickel-gdb-v6.log 2>&1
