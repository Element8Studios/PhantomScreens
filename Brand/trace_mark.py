"""Trace the white Phantom mark into an SVG path (potrace)."""
import sys
import numpy as np
import potrace
from PIL import Image

src, out_svg = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGBA')
alpha = im.getchannel('A')
S = 6
big = alpha.resize((im.width * S, im.height * S), Image.LANCZOS)
# potracer traces the False pixels, so pass the mark as False.
bits = np.array(big) <= 127
path = potrace.Bitmap(bits).trace(turdsize=20, alphamax=1.0, opticurve=True, opttolerance=0.2)

W, H = im.width, im.height
def f(p):
    return f"{p.x / S:.2f} {p.y / S:.2f}"

d = []
for curve in path:
    d.append("M" + f(curve.start_point))
    for seg in curve.segments:
        if seg.is_corner:
            d.append("L" + f(seg.c) + "L" + f(seg.end_point))
        else:
            d.append("C" + f(seg.c1) + " " + f(seg.c2) + " " + f(seg.end_point))
    d.append("Z")
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">\n'
       f'  <path fill="#FFFFFF" fill-rule="evenodd" d="{"".join(d)}"/>\n</svg>\n')
open(out_svg, 'w').write(svg)
print('curves', len(path), 'svg bytes', len(svg))
