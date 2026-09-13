"""Append benign EV_SYN-only records to the nickel button backing.

The main thread drains /dev/input/event0 (redirected to this regular file)
via a poll-always-ready notifier; when the file is empty the shim parks it
in a 10ms-step blocking read and the event loop never resumes. A steady
stream of sync-only records (type=EV_SYN, code=SYN_REPORT, value=0 --
no keys, no-op for Qt) keeps the drain supplied so queued slots, timers
and the wifi state machine can run. No tree changes: target is scratch.
"""
import os
import struct
import sys
import time

path = os.path.join(
    os.environ.get("KOBO_EMU_ROOT", "/home/user/kobo-emu"),
    "build/rootfs-4.38.23684/tmp/kobo-button0.bin",
)
record = struct.Struct("iiHHI")
# Give Nickel ~4s to start up and wedge before streaming.
time.sleep(4)
deadline = time.time() + 62
count = 0
with open(path, "ab", buffering=0) as handle:
    while time.time() < deadline:
        now = time.time()
        handle.write(
            record.pack(int(now), int(now % 1 * 1_000_000), 0, 0, 0)
        )
        count += 1
        time.sleep(0.02)
print(f"button-stream: wrote {count} syn records", file=sys.stderr)
