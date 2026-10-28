# Draws the launcher icon into assets/icon/: a waveform that settles into one
# written line (voice becomes text). One color plus alpha, so the same mask
# works as the Android 13 themed (monochrome) icon.
#
# Usage: python tool/make_icon.py, then dart run flutter_launcher_icons
# Needs Pillow (pip install pillow).

import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"
BG = (63, 81, 181, 255)  # keep in sync with adaptive_icon_background in pubspec.yaml
S = 4  # supersample factor for antialiasing
BAR_W = 60
BARS = (150, 330, 470, 250)  # bar heights, left to right
LINE_H = 76  # a bit thicker than the bars so it holds up at 24 px


def pill(d, x0, y0, x1, y1):
    r = min(x1 - x0, y1 - y0) / 2
    d.rounded_rectangle([v * S for v in (x0, y0, x1, y1)], radius=r * S, fill=255)


m = Image.new("L", (1024 * S, 1024 * S), 0)
d = ImageDraw.Draw(m)
for i, h in enumerate(BARS):
    x = 222 + i * (BAR_W + 34)
    pill(d, x, 512 - h / 2, x + BAR_W, 512 + h / 2)
pill(d, 222 + len(BARS) * (BAR_W + 34), 512 - LINE_H / 2, 802, 512 + LINE_H / 2)
m = m.resize((1024, 1024), Image.LANCZOS)

# Every opaque pixel must sit inside the adaptive icon safe zone (66 of 108 dp).
lim = 1024 * 33 / 108
px = m.load()
far = max(
    math.hypot(x - 511.5, y - 511.5)
    for y in range(1024)
    for x in range(1024)
    if px[x, y] > 8
)
assert far <= lim, f"glyph reaches {far:.0f}px, safe zone is {lim:.0f}px"

fg = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
fg.paste((255, 255, 255, 255), mask=m)
fg.save(OUT / "icon_foreground.png")
fg.save(OUT / "icon_monochrome.png")
icon = Image.new("RGBA", (1024, 1024), BG)
icon.alpha_composite(fg)
icon.save(OUT / "icon.png")
print(f"ok, glyph radius {far:.0f}/{lim:.0f}px")
