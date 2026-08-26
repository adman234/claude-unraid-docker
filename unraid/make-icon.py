#!/usr/bin/env python3
"""Generate unraid/claude-code.png -- the container icon shown in the Unraid UI.

No third-party dependencies: renders with supersampled distance fields and
writes the PNG by hand, so it can be regenerated anywhere.
"""
import math
import struct
import zlib
from pathlib import Path

SIZE = 256
SS = 3  # supersampling factor
BG = (0x26, 0x25, 0x22)
BG_EDGE = (0x17, 0x16, 0x15)
FG = (0xD9, 0x77, 0x57)
RADIUS = 58


def rounded_rect_sdf(x, y, w, h, r):
    """Signed distance to a rounded rectangle centred on (w/2, h/2)."""
    qx = abs(x - w / 2) - (w / 2 - r)
    qy = abs(y - h / 2) - (h / 2 - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def segment_sdf(px, py, ax, ay, bx, by):
    """Signed distance to a line segment (round caps come from thresholding)."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    denom = vx * vx + vy * vy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    return math.hypot(wx - t * vx, wy - t * vy)


def mix(c0, c1, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c0, c1))


def main():
    # ">_" -- a shell prompt, which is exactly what this container gives you.
    stroke = 19.0
    chevron = [(80, 84, 132, 128), (132, 128, 80, 172)]
    underscore = [(150, 172, 196, 172)]
    strokes = chevron + underscore

    rows = []
    n = SS * SS
    for py in range(SIZE):
        row = bytearray([0])  # PNG filter type 0
        for px in range(SIZE):
            r_acc = g_acc = b_acc = a_acc = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS

                    outside = rounded_rect_sdf(x, y, SIZE, SIZE, RADIUS)
                    if outside > 0.75:
                        continue
                    cover = min(1.0, max(0.0, 0.5 - outside))

                    # Subtle vertical gradient so the tile doesn't read flat.
                    base = mix(BG, BG_EDGE, y / SIZE)

                    d = min(segment_sdf(x, y, *s) for s in strokes)
                    ink = min(1.0, max(0.0, (stroke / 2 - d) + 0.5))
                    col = mix(base, FG, ink)

                    r_acc += col[0]
                    g_acc += col[1]
                    b_acc += col[2]
                    a_acc += cover * 255
            row += bytes((r_acc // n, g_acc // n, b_acc // n, round(a_acc / n)))
        rows.append(bytes(row))

    raw = b"".join(rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")

    out = Path(__file__).with_name("claude-code.png")
    out.write_bytes(png)
    print(f"wrote {out} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
