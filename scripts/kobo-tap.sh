#!/usr/bin/env bash
# kobo-tap.sh — append one pressure-protocol tap to the guest touch backing.
#
# Usage:
#   kobo-tap.sh [--version V] --x X --y Y [--pressure P]
#
# Appends a single-touch tap (ABS_X/ABS_Y + ABS_PRESSURE contact confirm +
# BTN_TOUCH, framed by SYN_REPORT) with live host timestamps to
# build/rootfs-<V>/tmp/kobo-touch0.bin — the shim's event1 (touch
# controller) backing, so the tap reaches KOReader's touch reader and not
# the event0 button poll. Coordinates are RAW touch values (what the device
# reports); see README §B.8 for the portrait + mirror-X mapping KOReader
# applies on top.
#
# --fifo targets the FIFO transport (nickel/koreader modes): the open is
# non-blocking and fails loudly when no guest reader holds the FIFO, so a
# tap can never vanish silently. Without --fifo the tap is appended to the
# regular-file backing (test mode).
#
# Fails loudly when the backing is absent (guest not staged/running) or the
# coordinates are malformed.
set -euo pipefail

VERSION="4.38.23684"
X=""
Y=""
PRESSURE="53"
FIFO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?kobo-tap: error: --version needs a value}"; shift 2 ;;
    --x) X="${2:?kobo-tap: error: --x needs a value}"; shift 2 ;;
    --y) Y="${2:?kobo-tap: error: --y needs a value}"; shift 2 ;;
    --pressure) PRESSURE="${2:?kobo-tap: error: --pressure needs a value}"; shift 2 ;;
    --fifo) FIFO=1; shift ;;
    --help|-h) echo "Usage: kobo-tap.sh [--version V] --x X --y Y [--pressure P] [--fifo]"; exit 0 ;;
    --*) echo "kobo-tap: error: unknown flag: $1" >&2; exit 1 ;;
    *) echo "kobo-tap: error: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$X" && -n "$Y" ]] \
  || { echo "kobo-tap: error: --x and --y are required" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "kobo-tap: error: malformed version '$VERSION'" >&2; exit 1; }
[[ "$X" =~ ^[0-9]+$ && "$Y" =~ ^[0-9]+$ && "$PRESSURE" =~ ^[0-9]+$ ]] \
  || { echo "kobo-tap: error: --x/--y/--pressure must be non-negative integers" >&2; exit 1; }

BACKING="build/rootfs-$VERSION/tmp/kobo-touch0.bin"
[[ -e "$BACKING" ]] \
  || { echo "kobo-tap: error: backing $BACKING absent (stage the guest first)" >&2; exit 1; }
if [[ "$FIFO" == "1" && ! -p "$BACKING" ]]; then
  echo "kobo-tap: error: $BACKING is not a FIFO (nickel/koreader mode stages one)" >&2
  exit 1
fi

python3 - "$BACKING" "$X" "$Y" "$PRESSURE" "$FIFO" <<'PYEOF'
import errno, os, struct, sys, time

backing, x, y, pressure = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
fifo = sys.argv[5] == "1"

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 0x18
BTN_TOUCH = 0x14A

now = time.time()
tap = [
    (EV_ABS, ABS_X, x),
    (EV_ABS, ABS_Y, y),
    (EV_ABS, ABS_PRESSURE, pressure),
    (EV_KEY, BTN_TOUCH, 1),
    (EV_SYN, 0, 0),
    (EV_ABS, ABS_PRESSURE, 0),
    (EV_KEY, BTN_TOUCH, 0),
    (EV_SYN, 0, 0),
]
record = struct.Struct("iiHHI")
payload = b"".join(
    record.pack(int(stamp), int((stamp % 1) * 1000000), kind, code, value)
    for stamp, (kind, code, value)
    in ((now + index * 0.001, event) for index, event in enumerate(tap))
)
if fifo:
    # Non-blocking open: ENXIO means no guest reader — fail loudly instead
    # of hanging or dropping the tap. One write: atomic under PIPE_BUF, so
    # the guest wakes with the whole tap at once, like a hardware IRQ burst.
    try:
        fd = os.open(backing, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        sys.exit("kobo-tap: error: no guest reader on %s: %s" % (backing, exc))
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
else:
    with open(backing, "ab") as handle:
        handle.write(payload)
print("kobo-tap: tap (%d,%d) pressure=%d appended to %s" % (x, y, pressure, backing))
PYEOF
