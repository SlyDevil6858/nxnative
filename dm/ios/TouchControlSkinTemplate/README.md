# NXNative touch-control skin template

This folder contains editable SVG starting points for the built-in touch-control layout.

## Make a skin

1. Open `skin-2d-template.svg` and `skin-3d-template.svg` in Photoshop (or another SVG-capable editor).
2. Keep the canvas size and the controls in their original positions if you want the artwork to line up with the built-in touch zones.
3. Export each canvas as a transparent PNG. Name the exports exactly:
   - `skin-2d.png`
   - `skin-3d.png`
4. Put both PNGs in one folder. In the game's launcher, choose **Import a skin folder…** and select that folder.

The supplied template canvas is 896 × 414 (iPhone 11 landscape points). The app scales the PNG to the gamepad view, so a different device aspect ratio may stretch the artwork. For best alignment, adjust the canvas to your device's landscape screenshot dimensions while keeping the controls aligned to the same relative safe-area positions.

## Revert

Choose **Use built-in controls** in the launcher. The imported artwork is only a visual overlay: the native touch zones, button mapping, stick behavior, and 2D/3D layout switching remain unchanged.

A skin folder must contain both PNG files at its top level. The app copies the folder into its own Documents directory, so the original folder can be moved or deleted afterward.
