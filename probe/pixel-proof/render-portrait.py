#!/usr/bin/env python3
"""Render raw RGB32 portrait dump straight to PNG (stdlib only, no rotation).
Usage: render-portrait.py <qimage.bin> <out.png>
Reuses the PNG writer pattern from shims/fb-dump.py (600x800 RGB32 LE 0xFFRRGGBB).
"""
import struct, sys, zlib

def chunk(tag, data):
    out = struct.pack(">I", len(data)) + tag + data
    return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

src, dst = sys.argv[1], sys.argv[2]
W, H = 600, 800
raw = open(src, "rb").read()
assert len(raw) == W * H * 4, len(raw)
words = struct.unpack("<%dI" % (W * H), raw)
rows = []
for y in range(H):
    row = bytearray()
    base = y * W
    for x in range(W):
        w = words[base + x]
        row += bytes(((w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF))
    rows.append(bytes(row))
raw_png = b"".join(b"\x00" + r for r in rows)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw_png, 9))
       + chunk(b"IEND", b""))
open(dst, "wb").write(png)
print("render-portrait: %s -> %s (%dx%d)" % (src, dst, W, H))
