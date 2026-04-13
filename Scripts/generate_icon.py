#!/usr/bin/env python3
"""
Generates AppIcon PNG files for DiskMapper without third-party libraries.

Uses only the macOS built-in `CGContext` via ctypes / subprocess-free approach:
generates PNG data directly using the `struct` + zlib approach (raw PNG encoder).

Run from the repo root:
    python3 Scripts/generate_icon.py
"""

import struct, zlib, os, math

OUTPUT_DIR = "Sources/DiskMapperApp/Assets.xcassets/AppIcon.appiconset"

SIZES = [16, 32, 64, 128, 256, 512, 1024]


# ── Minimal PNG writer ────────────────────────────────────────────────────────

def png_chunk(name: bytes, data: bytes) -> bytes:
    c = struct.pack(">I", len(data)) + name + data
    return c + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)

def write_png(pixels: list[list[tuple]], path: str):
    """pixels[y][x] = (r, g, b, a) each 0-255."""
    h = len(pixels)
    w = len(pixels[0]) if h else 0
    raw = b""
    for row in pixels:
        raw += b"\x00"  # filter type None
        for (r, g, b, a) in row:
            raw += bytes([r, g, b, a])
    compressed = zlib.compress(raw, 9)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)[:13])
        + png_chunk(b"IDAT", compressed)
        + png_chunk(b"IEND", b"")
    )
    # Fix: IHDR is always 13 bytes, rebuild properly
    ihdr_data = struct.pack(">II", w, h) + bytes([8, 6, 0, 0, 0])  # 8-bit RGBA
    data = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr_data)
        + png_chunk(b"IDAT", compressed)
        + png_chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(data)


# ── Drawing primitives ────────────────────────────────────────────────────────

def clamp(v, lo=0, hi=255):
    return max(lo, min(hi, int(v)))

def blend(dst, src_r, src_g, src_b, src_a):
    """Alpha-composite src over dst (r,g,b,a)."""
    a = src_a / 255.0
    r = clamp(src_r * a + dst[0] * (1 - a))
    g = clamp(src_g * a + dst[1] * (1 - a))
    b = clamp(src_b * a + dst[2] * (1 - a))
    return (r, g, b, 255)

def fill_rect(pixels, x0, y0, x1, y1, r, g, b, a=255):
    h = len(pixels)
    w = len(pixels[0]) if h else 0
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            pixels[y][x] = blend(pixels[y][x], r, g, b, a)

def rounded_rect(pixels, x0, y0, x1, y1, radius, r, g, b, a=255):
    """Fill a rounded rectangle."""
    radius = min(radius, (x1 - x0) // 2, (y1 - y0) // 2)
    # Fill three non-corner rectangles
    fill_rect(pixels, x0 + radius, y0,        x1 - radius, y1,        r, g, b, a)
    fill_rect(pixels, x0,          y0 + radius, x0 + radius, y1 - radius, r, g, b, a)
    fill_rect(pixels, x1 - radius, y0 + radius, x1,          y1 - radius, r, g, b, a)
    # Fill four corner circles
    for cx, cy in [(x0 + radius, y0 + radius), (x1 - radius, y0 + radius),
                   (x0 + radius, y1 - radius), (x1 - radius, y1 - radius)]:
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                dist = math.sqrt(dx*dx + dy*dy)
                if dist <= radius - 0.5:
                    aa = 255
                elif dist <= radius + 0.5:
                    aa = int((radius + 0.5 - dist) * 255)
                else:
                    continue
                px, py = cx + dx, cy + dy
                if 0 <= px < len(pixels[0]) and 0 <= py < len(pixels):
                    pixels[py][px] = blend(pixels[py][px], r, g, b, min(a, aa))


# ── Icon design ───────────────────────────────────────────────────────────────
#
# Dark background, 6 coloured rounded-rect "treemap" cells.
# Layout is in 0..1 unit space, scaled to each target size.

CELLS = [
    # (x0, y0, x1, y1 in 0..1, r, g, b)
    (0.04, 0.04, 0.55, 0.58,   64, 128, 230),   # blue    - video
    (0.04, 0.61, 0.55, 0.96,   76, 190, 140),   # green   - images
    (0.58, 0.04, 0.96, 0.34,   64, 185, 185),   # teal    - audio
    (0.58, 0.37, 0.96, 0.62,   230, 165,  50),  # amber   - documents
    (0.58, 0.65, 0.96, 0.84,   165,  89, 204),  # purple  - archives
    (0.58, 0.87, 0.96, 0.96,   217,  76,  64),  # red     - code
]

def render(size: int) -> list:
    s = size
    # RGBA canvas, transparent
    pixels = [[(0, 0, 0, 0)] * s for _ in range(s)]

    # Background: dark rounded rect
    bg_radius = max(1, int(s * 0.18))
    rounded_rect(pixels, 0, 0, s, s, bg_radius, 26, 26, 28, 255)

    # Cells
    pad = max(1, int(s * 0.03))
    cell_radius = max(1, int(s * 0.025))
    for (fx0, fy0, fx1, fy1, r, g, b) in CELLS:
        x0 = int(fx0 * s) + pad
        y0 = int(fy0 * s) + pad
        x1 = int(fx1 * s) - pad
        y1 = int(fy1 * s) - pad
        if x1 > x0 and y1 > y0:
            rounded_rect(pixels, x0, y0, x1, y1, cell_radius, r, g, b, 224)
            # Inner border (darker)
            if size >= 64:
                for bx in range(x0, x1):
                    if 0 <= y0 < s: pixels[y0][bx] = blend(pixels[y0][bx], 0, 0, 0, 60)
                    if 0 <= y1-1 < s: pixels[y1-1][bx] = blend(pixels[y1-1][bx], 0, 0, 0, 60)
                for by in range(y0, y1):
                    if 0 <= x0 < s: pixels[by][x0] = blend(pixels[by][x0], 0, 0, 0, 60)
                    if 0 <= x1-1 < s: pixels[by][x1-1] = blend(pixels[by][x1-1], 0, 0, 0, 60)

    return pixels


# ── Main ──────────────────────────────────────────────────────────────────────

os.makedirs(OUTPUT_DIR, exist_ok=True)
for sz in SIZES:
    name = f"AppIcon-{sz}"
    path = f"{OUTPUT_DIR}/{name}.png"
    pix = render(sz)
    write_png(pix, path)
    print(f"  ✓  {path}  ({sz}×{sz})")

print("Done.")
