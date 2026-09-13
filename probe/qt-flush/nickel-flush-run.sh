#!/usr/bin/env bash
# Step 1 probe: plain Nickel run with KOBO_DEBUG_FLUSHES=1.
# Mirrors scripts/run-usermode.sh nickel staging + nickel-gdb-run.sh env,
# plus KOBO_DEBUG_FLUSHES=1. No tree changes; all logs in /tmp/opencode/.
set -euo pipefail
cd /home/user/kobo-emu
VERSION="4.38.23684"
ROOT="build/rootfs-$VERSION"
TIMEOUT="${1:-60}"

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
        st = os.lstat(p)
        import stat as stmod
        if not stmod.S_ISFIFO(st.st_mode):
            os.remove(p)
            os.mkfifo(p, 0o644)
    except OSError:
        os.mkfifo(p, 0o644)
print("flush-probe: staged fb backing + touch/button FIFOs")
PYEOF
: > /tmp/kobo-shim.log || true

FAKEBIN_LOG="/tmp/opencode/fakebin-flush.log"
: > "$FAKEBIN_LOG"
: > /tmp/opencode/nickel-flush.log
QEMU_ARM="$(command -v qemu-arm)"
env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  timeout "$TIMEOUT" "$QEMU_ARM" -L "$ROOT" \
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
  >/tmp/opencode/nickel-flush.log 2>&1 || rc=$?
echo "flush-probe: rc=$rc (124 = still running at timeout)"
