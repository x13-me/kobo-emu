#!/usr/bin/env python3
"""Kobo N905 (800x600) virtual-framebuffer helpers, stdlib only.

Two subcommands:
  gen <out.raw565>    write an 800x600 RGB565 test card (gradient + border + bars)
  encode <in.raw565|fb0> <out.png>   convert raw RGB565 to 8-bit grayscale PNG

No third-party deps: PNG writer uses struct/zlib/binascii only.
"""
import binascii
import struct
import sys
import zlib

WIDTH = 800
HEIGHT = 600


def fail(msg):
    print(f"fb-proof: error: {msg}", file=sys.stderr)
    sys.exit(1)


def generate_test_card(path):
    if WIDTH <= 0 or HEIGHT <= 0:
        fail("invalid dimensions")
    pixels = bytearray(WIDTH * HEIGHT * 2)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            border = x < 8 or y < 8 or x >= WIDTH - 8 or y >= HEIGHT - 8
            if border:
                r = g = b = 31 if (x + y) % 2 == 0 else 0
                r5, g6, b5 = (31, 63, 31) if (x + y) % 2 == 0 else (0, 0, 0)
            elif y < 120:
                # Title band: 16 vertical gray steps.
                step = min(x // 50, 15)
                level = step * 17  # 0..255
                r5, g6, b5 = level >> 3, level >> 2, level >> 3
            elif y < 480:
                # Main area: horizontal gradient + centered dark bar + crosshair.
                level = (x * 255) // (WIDTH - 1)
                r5, g6, b5 = level >> 3, level >> 2, level >> 3
                if 250 <= y < 350:
                    r5, g6, b5 = 0, 0, 0
                if x == WIDTH // 2 or y == 300:
                    r5, g6, b5 = 0, 0, 0
            else:
                # Bottom band: 8 color bars (R/G/B ramps in RGB565).
                band = min(x // 100, 7)
                r5 = 31 if band in (0, 3, 4, 7) else 0
                g6 = 63 if band in (1, 3, 5, 7) else 0
                b5 = 31 if band in (2, 4, 5, 7) else 0
                if band == 6:  # white bar
                    r5, g6, b5 = 31, 63, 31
            v = (r5 << 11) | (g6 << 5) | b5
            struct.pack_into("<H", pixels, (y * WIDTH + x) * 2, v)
    with open(path, "wb") as f:
        f.write(pixels)
    print(f"fb-proof: wrote {path} ({WIDTH}x{HEIGHT} RGB565, {len(pixels)} bytes)")


def rgb565_to_gray(raw):
    expected = WIDTH * HEIGHT * 2
    if len(raw) != expected:
        fail(f"expected {expected} bytes, got {len(raw)}")
    gray = bytearray(WIDTH * HEIGHT)
    for i in range(WIDTH * HEIGHT):
        v = struct.unpack_from("<H", raw, i * 2)[0]
        r8 = ((v >> 11) & 0x1F) * 255 // 31
        g8 = ((v >> 5) & 0x3F) * 255 // 63
        b8 = (v & 0x1F) * 255 // 31
        gray[i] = (77 * r8 + 150 * g8 + 29 * b8) >> 8
    return gray


def write_png(path, gray):
    def chunk(ctype, data):
        c = struct.pack(">I", len(data)) + ctype + data
        return c + struct.pack(">I", binascii.crc32(ctype + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 0, 0, 0, 0)
    rows = b"".join(b"\x00" + gray[y * WIDTH:(y + 1) * WIDTH] for y in range(HEIGHT))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)
    print(f"fb-proof: wrote {path} ({WIDTH}x{HEIGHT} gray8, {len(png)} bytes)")


def main(argv):
    if len(argv) != 3 or argv[1] not in ("gen", "encode"):
        fail("usage: fb-proof.py gen <out.raw565> | encode <in.raw565> <out.png>")
    if argv[1] == "gen":
        generate_test_card(argv[2])
        return
    with open(argv[2], "rb") as f:
        raw = f.read()
    write_png(argv[3], rgb565_to_gray(raw))


if __name__ == "__main__":
    main(sys.argv)
