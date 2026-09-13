#!/usr/bin/env bash
# strace_window.sh — short strace capture of Nickel with EV_SYN stream.
# Replicates run-usermode.sh nickel staging (scratch only) + GUEST_ENV,
# then runs qemu-arm -strace for 40s while the /tmp EV_SYN streamer feeds
# the button backing. All outputs go to /tmp (no repo-tree changes).
set -uo pipefail

ROOT="build/rootfs-4.38.23684"
QEMU="/nix/store/603z0sssjvbii3j583f31ylc3kbixgr7-qemu-9.2.4/bin/qemu-arm"
FAKEBIN_LOG="/tmp/strace-fakebin.log"
: > "$FAKEBIN_LOG"

python3 - "$ROOT" <<'PYEOF'
import os, struct, sys
root = sys.argv[1]
tmp = os.path.join(root, "tmp")
with open(os.path.join(tmp, "kobo-fb0.bin"), "wb") as handle:
    handle.truncate(800 * 600 * 2)
open(os.path.join(tmp, "kobo-shim.log"), "w").close()
event = struct.Struct("iiHHI")
tap = [(3, 0, 400), (3, 1, 300), (1, 0x14A, 1), (0, 0, 0),
       (1, 0x14A, 0), (0, 0, 0)]
for name in ("kobo-touch0.bin", "kobo-button0.bin"):
    with open(os.path.join(tmp, name), "wb") as handle:
        for index, (kind, code, value) in enumerate(tap):
            handle.write(event.pack(index, 1000 * index, kind, code, value))
print("strace_window: re-seeded fb + tap backings")
PYEOF

python3 /tmp/evsyn_stream.py "$ROOT/tmp/kobo-button0.bin" 60 \
    > /tmp/evsyn_stream2.log 2>&1 &
STREAMER=$!
sleep 1 # let the streamer boot so the re-seed above reads as fresh staging

# Re-touch: guarantees button mtime >= streamer boot (seed ran before it).
touch "$ROOT/tmp/kobo-button0.bin"

env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
  timeout 40 "$QEMU" -L "$ROOT" -strace \
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
  "$ROOT/usr/local/Kobo/nickel" \
  -platform kobo -skipFontLoad > /tmp/strace-stdout.log 2> /tmp/strace-nickel.log || rc=$?
kill "$STREAMER" 2>/dev/null
wait 2>/dev/null
echo "strace_window: rc=${rc:-0} (124 = still running at timeout)"
cat /tmp/evsyn_stream2.log
ls -la /tmp/strace-nickel.log
