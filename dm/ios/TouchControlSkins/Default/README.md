# Default touch-control skin source files

This folder contains one editable SVG per virtual control. These are separate artwork sources for the built-in-style starter skin.

## Export for NXNative

Export each SVG as a transparent PNG with the **same base filename** (for example, `a.svg` → `a.png`). Keep the full 256 × 256 canvas and transparent margins. Put all 21 PNGs together in one folder, then import that folder from the game's launcher.

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
- `right-stick-base.png`
- `right-stick-knob.png`

Each D-pad direction is a separate image with a shared canvas so the four pieces line up. The app positions every image at the corresponding native touch-control location. Do not combine the images into one canvas. The image art is visual only; touch hit areas and button mapping remain native.

The built-in controls remain the fallback when no custom skin is selected. These SVGs are editable starter artwork; export them to PNG before importing them as a custom skin.
