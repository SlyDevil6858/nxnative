# Default touch-control skin source files

This folder contains one editable SVG per virtual control. These are the source artwork files for the built-in-style starter skin.

## Image files expected by NXNative

Export each SVG as a transparent PNG with the **same base filename** (for example, `a.svg` → `a.png`). Keep the full canvas and transparent margins. Put all 19 PNGs together in one folder, then import that folder from the game's launcher.

Required files:
- `a.png`
- `b.png`
- `x.png`
- `y.png`
- `stick-base.png`
- `stick-knob.png`
- `zl.png`
- `l.png`
- `zr.png`
- `r.png`
- `minus.png`
- `plus.png`
- `layout.png`
- `dpad-up.png`
- `dpad-down.png`
- `dpad-left.png`
- `dpad-right.png`
- `l3.png`
- `r3.png`

The app places each image at the corresponding native touch-control position. Do not combine the images into a single canvas. The image art is visual only; touch hit areas and button mapping remain native.

The built-in controls remain the fallback when no custom skin is selected. These SVGs are editable starter artwork, not a runtime skin folder until exported to PNG.
