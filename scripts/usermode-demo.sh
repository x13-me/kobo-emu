#!/usr/bin/env bash
# usermode-demo.sh — Track B proof: Kobo ARM userspace under qemu-arm
# with a virtual framebuffer file + synthetic touch pipe, emitting a PNG.
#
# What it proves (full-system boot is blocked on the i.MX50 machine model):
#   1. qemu-arm runs KoboRoot ARM binaries (busybox uname).
#   2. Display pipeline concept: host draws an 800x600 RGB565 test card,
#      the GUEST performs the frame copy into a virtual framebuffer file
#      (stand-in for /dev/fb0), host converts the guest-written frame to PNG.
#   3. Touch injection concept: synthetic tap lines through a FIFO show up
#      in the guest-side event log.
#   4. Nickel load probe (EXPECTED TO FAIL): records the exact missing-lib
#      set blocking Nickel, for the Phase-4 factory-lib work.
#
# Usage:
#   usermode-demo.sh [--version V]
#
# Needs: qemu-arm + python3 in PATH (enter 'nix develop' first).
# Outputs: logs/usermode-demo-<version>.log  logs/fb-proof-<version>.png
set -euo pipefail

readonly DEFAULT_VERSION="${KOBO_VERSION:-4.38.23684}"
readonly FB_W=800
readonly FB_H=600

die() {
  echo "usermode-demo: error: $*" >&2
  exit 1
}

print_usage() {
  cat <<'USAGE'
Usage: usermode-demo.sh [--version V]
USAGE
}

# Guest calls must not see the host's LD_LIBRARY_PATH (an appimage-run
# pipewire path leaks in on this host and breaks the ARM loader): every
# qemu-arm invocation goes through this wrapper with a clean environment.
guest_run() {
  env -u LD_LIBRARY_PATH qemu-arm -L "$ROOTFS" "$@"
}

main() {
  local version="$DEFAULT_VERSION"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:?usermode-demo: error: --version needs a value}"; shift 2 ;;
      --help|-h) print_usage; exit 0 ;;
      --*) die "unknown flag: $1 (see --help)" ;;
      *) die "unexpected extra argument: $1" ;;
    esac
  done
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "malformed version '$version' (want MAJOR.MINOR.BUILD)"

  command -v qemu-arm >/dev/null \
    || die "qemu-arm not in PATH (enter 'nix develop')"
  command -v python3 >/dev/null \
    || die "python3 not in PATH (enter 'nix develop')"
  command -v timeout >/dev/null \
    || die "timeout(1) not in PATH (coreutils missing)"

  ROOTFS="build/rootfs-$version"
  [[ -d "$ROOTFS" ]] \
    || die "missing $ROOTFS — build it with: scripts/build-sd.sh $version"
  [[ -x "$ROOTFS/bin/busybox" ]] \
    || die "missing $ROOTFS/bin/busybox"
  export ROOTFS

  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    echo "usermode-demo: note: unsetting leaked LD_LIBRARY_PATH for guest calls"
    unset LD_LIBRARY_PATH
  fi

  local demo_dir="$ROOTFS/tmp/kobo-demo"
  local log="logs/usermode-demo-$version.log"
  local png="logs/fb-proof-$version.png"
  mkdir -p logs "$demo_dir"
  rm -rf "$demo_dir"
  mkdir -p "$demo_dir"
  : > "$log" || die "cannot write log $log"

  {
    echo "=== 1. guest binary identity (qemu-arm + Kobo busybox) ==="
    guest_run "$ROOTFS/bin/busybox" uname -a

    echo "=== 2. host draws ${FB_W}x${FB_H} RGB565 test card ==="
    KFB_PATTERN="$demo_dir/fb-pattern.raw565" KFB_W="$FB_W" KFB_H="$FB_H" python3 - <<'PYEOF'
import os, struct
w, h = int(os.environ["KFB_W"]), int(os.environ["KFB_H"])
def rgb565(r, g, b):
    return struct.pack("<H", ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
px = bytearray()
for y in range(h):
    for x in range(w):
        border = x < 8 or y < 8 or x >= w - 8 or y >= h - 8
        if border:
            c = (255, 255, 255)
        elif y < 120:  # top color bars: red green blue white grey black
            c = [(255, 0, 0), (0, 255, 0), (0, 0, 255),
                 (255, 255, 255), (128, 128, 128), (0, 0, 0)][(x * 6) // w]
        elif y < 480:  # mid grey ramp (e-ink-ish gradient)
            v = (x * 255) // w
            c = (v, v, v)
        else:  # bottom checkerboard
            c = (255, 255, 255) if ((x // 40) + (y // 40)) % 2 == 0 else (0, 0, 0)
        px += rgb565(*c)
with open(os.environ["KFB_PATTERN"], "wb") as f:
    f.write(px)
print(f"fb-proof: wrote {os.environ['KFB_PATTERN']} ({w}x{h} RGB565, {len(px)} bytes)")
PYEOF

    echo "=== 3. guest performs the frame copy (display flip) ==="
    guest_run "$ROOTFS/bin/busybox" dd \
      if=/tmp/kobo-demo/fb-pattern.raw565 of=/tmp/kobo-demo/fb0 bs=65536
    echo "=== 4. guest verifies frame integrity ==="
    guest_run "$ROOTFS/bin/busybox" md5sum /tmp/kobo-demo/fb-pattern.raw565 /tmp/kobo-demo/fb0

    echo "=== 5. synthetic touch: host taps -> guest event log ==="
    mkfifo "$demo_dir/touch.pipe"
    guest_run "$ROOTFS/bin/busybox" sh -c \
      'while IFS= read -r line; do echo "touch-event: $line"; done < /tmp/kobo-demo/touch.pipe' \
      > "$demo_dir/touch.log" 2>&1 &
    local reader_pid=$!
    sleep 1
    printf 'tap 400 300\ntap 120 500\ntap 700 100\n' > "$demo_dir/touch.pipe"
    wait "$reader_pid"
    cat "$demo_dir/touch.log"

    echo "=== 6. nickel load probe (expected failure: factory libs absent) ==="
    local nickel_rc=0
    guest_run "$ROOTFS/usr/local/Kobo/nickel" -platform kobo -skipFontLoad \
      > "$demo_dir/nickel-probe.out" 2>&1 || nickel_rc=$?
    head -3 "$demo_dir/nickel-probe.out"
    if [[ "$nickel_rc" -eq 0 ]]; then
      echo "nickel: unexpectedly started (rc=0)"
    else
      echo "nickel: failed to load as expected (rc=$nickel_rc)"
    fi

    echo "=== 7. host converts guest-written frame to PNG ==="
    KFB_FRAME="$demo_dir/fb0" KFB_PNG="$png" KFB_W="$FB_W" KFB_H="$FB_H" python3 - <<'PYEOF'
import os, struct, zlib
w, h = int(os.environ["KFB_W"]), int(os.environ["KFB_H"])
with open(os.environ["KFB_FRAME"], "rb") as f:
    raw = f.read()
assert len(raw) == w * h * 2, f"frame size {len(raw)}, want {w*h*2}"
px = bytearray(w * h * 3)
for i in range(0, len(raw), 2):
    v = struct.unpack_from("<H", raw, i)[0]
    o = (i // 2) * 3
    px[o] = ((v >> 11) & 0x1F) * 255 // 31
    px[o + 1] = ((v >> 5) & 0x3F) * 255 // 63
    px[o + 2] = (v & 0x1F) * 255 // 31
rows = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))
def chunk(ctype, data):
    body = ctype + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))
with open(os.environ["KFB_PNG"], "wb") as f:
    f.write(png)
print(f"fb-proof: wrote {os.environ['FB_PNG']} ({len(png)} bytes)")
PYEOF
    ls -la "$png"
    echo "usermode-demo: done (version=$version)"
  } 2>&1 | tee "$log"
}

main "$@"
