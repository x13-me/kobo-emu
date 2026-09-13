#!/usr/bin/env python3
"""fb-dump.py — dump a raw RGB565 framebuffer backing file to PNG (stdlib only).

Usage: fb-dump.py <backing.bin> <out.png> [--width 800] [--height 600]
Exits non-zero with a message on stderr when the backing size mismatches.
"""

import struct
import sys
import zlib


def fail(message):
    print("fb-dump: error: %s" % message, file=sys.stderr)
    sys.exit(1)


def write_png(path, width, height, rgb_rows):
    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rgb_rows)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(png)


def main(argv):
    if len(argv) < 3:
        fail("usage: fb-dump.py <backing.bin> <out.png> [--width W] [--height H]")
    backing_path, out_path = argv[1], argv[2]
    width, height = 800, 600
    for flag, value in zip(argv[3::2], argv[4::2]):
        if flag == "--width":
            width = int(value)
        elif flag == "--height":
            height = int(value)
        else:
            fail("unknown flag: %s" % flag)

    expected = width * height * 2
    try:
        with open(backing_path, "rb") as handle:
            pixels = handle.read()
    except OSError as exc:
        fail("cannot read %s: %s" % (backing_path, exc))
    if len(pixels) < expected:
        fail("%s holds %d bytes, need %d (%dx%d RGB565)"
             % (backing_path, len(pixels), expected, width, height))

    rows = []
    for y in range(height):
        row = bytearray()
        base = y * width * 2
        for x in range(width):
            word = pixels[base + 2 * x] | (pixels[base + 2 * x + 1] << 8)
            row += bytes((((word >> 11) & 0x1F) * 255 // 31,
                          ((word >> 5) & 0x3F) * 255 // 63,
                          (word & 0x1F) * 255 // 31))
        rows.append(bytes(row))
    write_png(out_path, width, height, rows)
    print("fb-dump: %s -> %s (%dx%d)" % (backing_path, out_path, width, height))


if __name__ == "__main__":
    main(sys.argv)
