# Brand assets

Phantom Screens brand artwork, supplied by the client and used with permission.

## Vector (`vector/`)

- `phantom-mark.svg`: the "P" mark, white, traced to Bézier curves from `source/mark-white.png`.
- `icon-classic.svg`: white mark on navy. The default app icon.
- `icon-pattern.svg`: classic plus the cyan X pattern at 23% opacity.
- `icon-light.svg`: navy mark on white.
- `icon-cyan.svg`: cyan mark on navy.
- `phantom-x-pattern.svg`: the X pattern on its own.

Colours: navy `#000A3E`, cyan `#86D9DD`, white `#FFFFFF`.

## Rebuilding

```sh
# 1. Trace the mark (needs `pip install potracer numpy pillow`)
python3 trace_mark.py source/mark-white.png vector/phantom-mark.svg
# 2. Render icons (PNG 1024 + 180 previews) and icon SVGs
python3 make_icons.py vector/phantom-mark.svg out/
```

Copy `out/icon-*-1024.png` into `Phantom/Assets.xcassets/AppIcon*.appiconset/icon-1024.png`
and the 180 px previews into the matching `IconPreview-*.imageset`.
