#!/usr/bin/env python3
"""Generate SQLink AppIcon (1024x1024 PNG) with no third-party deps."""
import struct, zlib, math

S = 1024
cx = S // 2
rx = 300          # half width of cylinder
ry = 72           # vertical radius of the cap ellipses
topY = 300
botY = 724

top_c = (20, 132, 205)
bot_c = (12, 78, 158)


def bg(y):
    t = y / (S - 1)
    return (
        int(top_c[0] * (1 - t) + bot_c[0] * t),
        int(top_c[1] * (1 - t) + bot_c[1] * t),
        int(top_c[2] * (1 - t) + bot_c[2] * t),
    )


def in_ellipse(x, y, cy, yr):
    dx = (x - cx) / rx
    dy = (y - cy) / yr
    return dx * dx + dy * dy <= 1.0


def inside(x, y):
    if topY <= y <= botY and abs(x - cx) <= rx:
        return True
    if in_ellipse(x, y, topY, ry):
        return True
    if in_ellipse(x, y, botY, ry):
        return True
    return False


def build():
    raw = bytearray()
    for y in range(S):
        raw.append(0)  # filter type 0
        for x in range(S):
            if inside(x, y):
                col = (255, 255, 255)
            else:
                col = bg(y)
            raw += bytes(col)
    return bytes(raw)


def png(data_rgba):
    def chunk(typ, body):
        c = typ + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(data_rgba, 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


if __name__ == "__main__":
    out = "SQLink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    with open(out, "wb") as f:
        f.write(png(build()))
    print("saved", out)
