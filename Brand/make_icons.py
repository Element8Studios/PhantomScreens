"""Builds Phantom Screens app icons and SVGs from the traced vector mark.

Usage: python3 make_icons.py phantom-mark.svg OUT_DIR
"""
import os
import re
import sys
from PIL import Image, ImageChops, ImageDraw

NAVY = (0, 10, 62)
CYAN = (134, 217, 221)
WHITE = (255, 255, 255)
SIZE = 1024
SS = 4                     # supersampling
MARK_HEIGHT = 0.56         # mark height as a fraction of the icon

mark_svg, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
svg = open(mark_svg).read()
vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
path_d = re.search(r' d="([^"]+)"', svg).group(1)


def parse(d):
    """Absolute M/L/C/Z path -> list of polygons (bezier curves flattened)."""
    tokens = re.findall(r'[MLCZ]|-?[\d.]+', d)
    polys, cur, pos, i = [], [], None, 0
    while i < len(tokens):
        t = tokens[i]
        if t == 'M':
            pos = (float(tokens[i + 1]), float(tokens[i + 2])); cur = [pos]; i += 3
        elif t == 'L':
            pos = (float(tokens[i + 1]), float(tokens[i + 2])); cur.append(pos); i += 3
        elif t == 'C':
            p = [float(x) for x in tokens[i + 1:i + 7]]
            c1, c2, e = (p[0], p[1]), (p[2], p[3]), (p[4], p[5])
            for k in range(1, 17):
                s = k / 16; u = 1 - s
                cur.append((u**3 * pos[0] + 3*u*u*s * c1[0] + 3*u*s*s * c2[0] + s**3 * e[0],
                            u**3 * pos[1] + 3*u*u*s * c1[1] + 3*u*s*s * c2[1] + s**3 * e[1]))
            pos = e; i += 7
        elif t == 'Z':
            polys.append(cur); cur = []; i += 1
        else:
            i += 1
    return polys


POLYS = parse(path_d)
MW, MH = vb[2], vb[3]


def mark_layer(size, color, height_frac):
    """Mark rendered with even-odd fill, centred, as an RGBA layer."""
    big = size * SS
    scale = big * height_frac / MH
    ox = (big - MW * scale) / 2
    oy = (big - MH * scale) / 2
    mask = Image.new('L', (big, big), 0)
    for poly in POLYS:
        m = Image.new('L', (big, big), 0)
        ImageDraw.Draw(m).polygon([(ox + x * scale, oy + y * scale) for x, y in poly], fill=255)
        mask = ImageChops.logical_xor(mask.convert('1'), m.convert('1')).convert('L')
    mask = mask.resize((size, size), Image.LANCZOS)
    layer = Image.new('RGBA', (size, size), color + (255,))
    layer.putalpha(mask)
    return layer


# X pattern lattice, in 680-px icon coordinates (from the supplied artwork).
X_CENTRES = [(177, 76), (65, 163), (566, 290), (678, 402), (566, 512), (454, 624), (678, 624)]
X_INNER, X_TIP, X_WIDTH = 13, 59, 15.6   # in 1024-px units


def pattern_layer(size, color, opacity):
    big = size * SS
    k = big / 680
    s = big / 1024
    layer = Image.new('L', (big, big), 0)
    draw = ImageDraw.Draw(layer)
    w = X_WIDTH * s
    for cx, cy in X_CENTRES:
        cx, cy = cx * k, cy * k
        for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
            a = (cx + dx * X_INNER * s, cy + dy * X_INNER * s)
            b = (cx + dx * X_TIP * s, cy + dy * X_TIP * s)
            draw.line([a, b], fill=255, width=round(w))
            for p in (a, b):
                draw.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=255)
    layer = layer.resize((size, size), Image.LANCZOS).point(lambda v: int(v * opacity))
    out_layer = Image.new('RGBA', (size, size), color + (255,))
    out_layer.putalpha(layer)
    return out_layer


VARIANTS = {
    # name: (background, mark colour, pattern?)
    'Classic': (NAVY, WHITE, False),
    'Pattern': (NAVY, WHITE, True),
    'Light': (WHITE, NAVY, False),
    'Cyan': (NAVY, CYAN, False),
}

for name, (bg, fg, pattern) in VARIANTS.items():
    icon = Image.new('RGBA', (SIZE, SIZE), bg + (255,))
    if pattern:
        icon.alpha_composite(pattern_layer(SIZE, CYAN, 0.23))
    icon.alpha_composite(mark_layer(SIZE, fg, MARK_HEIGHT))
    icon = icon.convert('RGB')
    icon.save(os.path.join(out, f'icon-{name.lower()}-1024.png'))
    icon.resize((180, 180), Image.LANCZOS).save(os.path.join(out, f'icon-{name.lower()}-180.png'))

# Vector versions of each icon.
def hexc(c): return '#%02X%02X%02X' % c
mark_scale = SIZE * MARK_HEIGHT / MH
mx, my = (SIZE - MW * mark_scale) / 2, (SIZE - MH * mark_scale) / 2
k = SIZE / 680
x_svg = []
for cx, cy in X_CENTRES:
    cx, cy = cx * k, cy * k
    for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        x_svg.append(f'<line x1="{cx + dx*X_INNER:.1f}" y1="{cy + dy*X_INNER:.1f}" '
                     f'x2="{cx + dx*X_TIP:.1f}" y2="{cy + dy*X_TIP:.1f}"/>')
for name, (bg, fg, pattern) in VARIANTS.items():
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">',
             f'  <rect width="{SIZE}" height="{SIZE}" fill="{hexc(bg)}"/>']
    if pattern:
        parts.append(f'  <g stroke="{hexc(CYAN)}" stroke-opacity="0.23" stroke-width="{X_WIDTH}" '
                     f'stroke-linecap="round">' + ''.join(x_svg) + '</g>')
    parts.append(f'  <path transform="translate({mx:.2f} {my:.2f}) scale({mark_scale:.5f})" '
                 f'fill="{hexc(fg)}" fill-rule="evenodd" d="{path_d}"/>')
    parts.append('</svg>')
    open(os.path.join(out, f'icon-{name.lower()}.svg'), 'w').write('\n'.join(parts) + '\n')

# Stand-alone pattern tile (cyan on transparent).
open(os.path.join(out, 'phantom-x-pattern.svg'), 'w').write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">\n'
    f'  <g stroke="{hexc(CYAN)}" stroke-width="{X_WIDTH}" stroke-linecap="round">' + ''.join(x_svg) + '</g>\n</svg>\n')
print('done', sorted(os.listdir(out)))
