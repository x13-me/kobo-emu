#!/usr/bin/env python3
"""Step2 offline convert: QImage RGB32 600x800 -> landscape RGB565 800x600.
Raw byte ops (no PIL). Writes into a COPY of the fb backing, never the live one.
Usage: convert-step2.py <qimage.bin> <out-backing-copy> <cw|ccw>
 Portrait src: W=600,H=800, words little-endian 0xFFRRGGBB.
 CW (portrait->landscape): dst 800x600, dst(dx,dy)=src(sx=dy, sy=(H-1-dx)).
 CCW: dst(dx,dy)=src(sx=(W-1-dy), sy=dx).
 RGB565 LE pack: r5=(r>>3), g6=(g>>2), b5=(b>>3); word=(r5<<11)|(g6<<5)|b5.
"""
import struct, sys

def fail(m):
    print("convert-step2: error: %s" % m, file=sys.stderr)
    sys.exit(1)

if len(sys.argv) != 4:
    fail("usage: convert-step2.py <qimage.bin> <out-copy.bin> <cw|ccw>")
src_path, out_path, direction = sys.argv[1], sys.argv[2], sys.argv[3]
if direction not in ("cw", "ccw"):
    fail("direction must be cw|ccw")

SW, SH = 600, 800
DW, DH = 800, 600
try:
    with open(src_path, "rb") as h:
        raw = h.read()
except OSError as e:
    fail("cannot read %s: %s" % (src_path, e))
if len(raw) != SW * SH * 4:
    fail("%s holds %d bytes, need %d" % (src_path, len(raw), SW * SH * 4))
words = struct.unpack("<%dI" % (SW * SH), raw)

out = bytearray(DW * DH * 2)
for dy in range(DH):
    for dx in range(DW):
        if direction == "cw":
            sx, sy = dy, (SH - 1 - dx)
        else:
            sx, sy = (SW - 1 - dy), dx
        w = words[sy * SW + sx]
        r, g, b = (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF
        word = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        o = (dy * DW + dx) * 2
        out[o] = word & 0xFF
        out[o + 1] = (word >> 8) & 0xFF
with open(out_path, "wb") as h:
    h.write(bytes(out))
print("convert-step2: %s -> %s (%s, %dx%d RGB565)" % (src_path, out_path, direction, DW, DH))
