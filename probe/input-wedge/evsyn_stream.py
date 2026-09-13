#!/usr/bin/env python3
"""Continuous EV_SYN stream into the Nickel button backing file.

Polls until run-usermode.sh re-stages the backing (mtime newer than this
script's start), then appends one 16-byte EV_SYN record (struct iiHHI)
every INTERVAL_S for STREAM_S seconds. Nickel's shim read() retry loop
picks appended bytes up like hardware IRQ arrivals.

Usage: evsyn_stream.py <backing_path> <stream_seconds>
"""
import os
import struct
import sys
import time

RECORD = struct.Struct("iiHHI")
INTERVAL_S = 0.02
STAGE_WAIT_S = 300
POLL_S = 0.5


def fail(message):
    print("evsyn_stream: error: %s" % message, file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        fail("usage: evsyn_stream.py <backing_path> <stream_seconds>")
    backing_path, stream_arg = sys.argv[1], sys.argv[2]
    try:
        stream_seconds = float(stream_arg)
    except ValueError:
        fail("stream_seconds not a number: %r" % stream_arg)
    if stream_seconds <= 0:
        fail("stream_seconds must be positive")

    boot_time = time.time()
    deadline = boot_time + STAGE_WAIT_S
    while time.time() < deadline:
        if os.path.exists(backing_path) and os.path.getmtime(backing_path) >= boot_time - 1:
            break
        time.sleep(POLL_S)
    else:
        fail("backing %s not re-staged within %ds" % (backing_path, STAGE_WAIT_S))

    try:
        handle = open(backing_path, "ab", buffering=0)
    except OSError as exc:
        fail("cannot open %s: %s" % (backing_path, exc))
    with handle:
        sent = 0
        end = time.time() + stream_seconds
        while time.time() < end:
            now = time.time()
            handle.write(RECORD.pack(int(now), int((now % 1) * 1e6), 0, 0, 0))
            sent += 1
            time.sleep(INTERVAL_S)
    print("evsyn_stream: done sent=%d backing=%s" % (sent, backing_path))


if __name__ == "__main__":
    main()
