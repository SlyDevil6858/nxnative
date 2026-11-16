# Touch Control Themes

These folders are imported from the in-game touch-control editor. They are kept outside the iOS app target, so adding a theme does not require rebuilding the IPA.

## Included themes

- Forest: the Forest color palette.

## Creating a theme

Duplicate a theme folder, edit its theme.json, and import the folder in the in-game editor. The six palette colors are required. Button colors are optional and override the palette fill for that control.

Supported button keys: A, B, X, Y, L, R, ZL, ZR, Stick, Minus, Plus, Dpad, and Layout. Colors use six-digit RGB hex values (for example, #295E40).
