# Regi app icons — midnight terminal

Everything Xcode needs to ship the icon, plus the source vector.

## Palette
- Background gradient: `#1E2A4A` → `#0A1228` (top-left → bottom-right)
- Foreground glyph: `#7AB0FF` (cyan-blue)

## What's in here

```
regi-icons/
├── AppIcon.appiconset/   ← drop this into your Asset Catalog (Assets.xcassets)
│   ├── Contents.json
│   └── icon_*.png        (10 sizes: 16, 32, 64, 128, 256, 512, 1024)
├── AppIcon.iconset/      ← classic .iconset folder, for `iconutil -c icns`
│   └── (same 10 PNGs)
├── regi_icon_1024.svg    ← cleaned 1024×1024 vector (no baked corners)
└── build_iconset.py      ← the script that built all of this
```

## Use in Xcode

1. Open your Xcode project.
2. Click `Assets.xcassets` in the project navigator.
3. Delete the existing `AppIcon` entry if there is one.
4. Drag `AppIcon.appiconset` from Finder into the asset catalog sidebar.
   Xcode reads `Contents.json` and fills every size slot.
5. Build & run. macOS rounds the corners automatically.

## Build a `.icns` (optional)

On your Mac, in this folder:

    iconutil -c icns AppIcon.iconset

## To tweak the palette

In `build_iconset.py` near the top:

    midnight_top    = "#1E2A4A"
    midnight_bottom = "#0A1228"
    GLYPH           = "#7AB0FF"

Edit and re-run: `python3 build_iconset.py`
