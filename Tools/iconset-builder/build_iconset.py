#!/usr/bin/env python3
"""
Build a macOS AppIcon.appiconset from the Regi SVG.

Steps:
1. Load the source SVG, normalize it to a square 1024x1024 canvas with
   transparent background (Xcode/macOS adds the squircle mask itself).
2. Render the cleaned SVG at every size macOS asks for.
3. Write a Contents.json that Xcode understands.
"""
import cairosvg
import json
import os
import re
import shutil
from pathlib import Path

SRC_SVG = Path("/home/claude/regi.svg")
OUT_DIR = Path("/home/claude/AppIcon.appiconset")

# Read original
raw = SRC_SVG.read_text()

# The original SVG has:
#   viewBox="0 0 150 137.7"
# and the first path draws a rounded-rectangle background using class cls-0.
# For macOS app icons we want:
#   - a SQUARE canvas (1024 viewBox)
#   - NO baked-in corner radius (the OS rounds it)
#   - the design centered, with a bit of padding so the squircle mask
#     doesn't crop the artwork.
#
# Strategy: extract the original viewBox content, drop the rounded background
# path (cls-0), then re-emit on a 1024x1024 canvas with a solid background
# rect underneath (filled with the original gradient) and the artwork
# centered & scaled inside it.

# Pull the gradient out so we can re-use it as our background fill.
# Override its stops with the "midnight terminal" palette.
grad_match = re.search(r"<linearGradient[^>]*>.*?</linearGradient>", raw, re.S)
original_gradient = grad_match.group(0) if grad_match else ""

# Replace the two original stops with midnight ink stops
midnight_top    = "#1E2A4A"  # lighter navy at the top
midnight_bottom = "#0A1228"  # deep ink at the bottom
gradient_block = re.sub(
    r'<stop[^/]*/>\s*<stop[^/]*/>',
    f'<stop stop-color="{midnight_top}" offset="0"/>\n    '
    f'<stop stop-color="{midnight_bottom}" offset="1"/>',
    original_gradient,
)

# Pull all foreground paths (cls-1 = the brown monitor + cursor).
# The original SVG declared `.cls-1 { fill: #3A2512 }` in a <style> block
# which cairosvg's CSS support drops when the style block is detached.
# Rewrite class="cls-1" -> fill="#7AB0FF" so the cyan glow color is inline.
GLYPH = "#7AB0FF"  # midnight-terminal cyan-blue
fg_paths = re.findall(r'<path class="cls-1"[^/]*/>', raw)
fg_paths = [p.replace('class="cls-1"', f'fill="{GLYPH}"') for p in fg_paths]
fg_block = "\n  ".join(fg_paths)

# The original viewBox is 150 x 137.7 but the *artwork* doesn't fill it —
# the monitor + cursor + stand actually live inside roughly
#   x = 25.8 ... 120.8  (width 95.1)
#   y = 21.8 ... 101.4  (height 79.6)
# (measured by rendering the original at 1024 and finding the espresso
# pixels' bounding box). We center on that bbox, not on the viewBox,
# otherwise the icon sits slightly high & off-axis.
SRC_W, SRC_H = 150.0, 137.7
CANVAS = 1024.0
ART_X0, ART_Y0 = 25.8, 21.8
ART_W,  ART_H  = 95.1, 79.6

# How much of the 1024 canvas the artwork should fill (Apple's safe zone
# is ~80% — leave room for the squircle mask and shadow).
TARGET_FILL = 0.80
scale = (CANVAS * TARGET_FILL) / max(ART_W, ART_H)
draw_w = ART_W * scale
draw_h = ART_H * scale
# Place the *artwork bbox* in the canvas center.
# After scaling, the artwork's local origin (0, 0) maps to
# (-ART_X0 * scale, -ART_Y0 * scale) before translation, so:
tx = (CANVAS - draw_w) / 2 - ART_X0 * scale
ty = (CANVAS - draw_h) / 2 - ART_Y0 * scale

clean_svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {int(CANVAS)} {int(CANVAS)}">
  <defs>
    {gradient_block}
  </defs>
  <rect width="{int(CANVAS)}" height="{int(CANVAS)}" fill="url(#SVGID_1_)"/>
  <g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.4f})">
    {fg_block}
  </g>
</svg>"""

# The gradient in the original references coordinates inside 150x137.7;
# now that the rect covers 1024x1024 the gradient stops still work because
# linearGradient defaults to gradientUnits="userSpaceOnUse" using the
# specified x1/x2/y1/y2 — but those small coordinates will compress the
# gradient into the corner. Switch it to objectBoundingBox so it stretches
# over the full square.
clean_svg = re.sub(
    r'<linearGradient([^>]*?)gradientUnits="userSpaceOnUse"([^>]*)>',
    r'<linearGradient\1\2>',
    clean_svg,
)
# And rewrite coordinates to 0..1 in bounding box space
clean_svg = re.sub(
    r'<linearGradient([^>]*?)x1="[^"]*"([^>]*?)x2="[^"]*"([^>]*?)y1="[^"]*"([^>]*?)y2="[^"]*"',
    r'<linearGradient\1x1="0"\2x2="1"\3y1="0"\4y2="1"',
    clean_svg,
)

CLEAN_SVG_PATH = Path("/home/claude/regi_clean.svg")
CLEAN_SVG_PATH.write_text(clean_svg)
print(f"Wrote cleaned 1024x1024 SVG -> {CLEAN_SVG_PATH}")

# Macos icon sizes Xcode currently wants for the new appiconset:
# Apple's modern Xcode (15+) can use a single 1024 image and slice it,
# but for maximum compatibility we generate the full classic set.
ICON_SPECS = [
    # (size in pt, scale, pixel size, filename)
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

if OUT_DIR.exists():
    shutil.rmtree(OUT_DIR)
OUT_DIR.mkdir(parents=True)

for size, scale_factor, fname in ICON_SPECS:
    pixels = size * scale_factor
    cairosvg.svg2png(
        url=str(CLEAN_SVG_PATH),
        write_to=str(OUT_DIR / fname),
        output_width=pixels,
        output_height=pixels,
    )
    print(f"  {fname:30s}  {pixels}x{pixels}")

# Contents.json for Xcode
contents = {
    "images": [
        {"size": "16x16",  "idiom": "mac", "scale": "1x", "filename": "icon_16x16.png"},
        {"size": "16x16",  "idiom": "mac", "scale": "2x", "filename": "icon_16x16@2x.png"},
        {"size": "32x32",  "idiom": "mac", "scale": "1x", "filename": "icon_32x32.png"},
        {"size": "32x32",  "idiom": "mac", "scale": "2x", "filename": "icon_32x32@2x.png"},
        {"size": "128x128","idiom": "mac", "scale": "1x", "filename": "icon_128x128.png"},
        {"size": "128x128","idiom": "mac", "scale": "2x", "filename": "icon_128x128@2x.png"},
        {"size": "256x256","idiom": "mac", "scale": "1x", "filename": "icon_256x256.png"},
        {"size": "256x256","idiom": "mac", "scale": "2x", "filename": "icon_256x256@2x.png"},
        {"size": "512x512","idiom": "mac", "scale": "1x", "filename": "icon_512x512.png"},
        {"size": "512x512","idiom": "mac", "scale": "2x", "filename": "icon_512x512@2x.png"},
    ],
    "info": {"version": 1, "author": "xcode"},
}
(OUT_DIR / "Contents.json").write_text(json.dumps(contents, indent=2))
print(f"\nWrote Contents.json")
print(f"\nDone — appiconset at: {OUT_DIR}")
