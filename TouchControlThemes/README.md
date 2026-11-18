# Touch Control Themes

Built-in themes are bundled into the IPA; additional themes can be imported by the user.

## Built-in themes

- `CLASSIC` — the brighter neutral-gray theme. It is always bundled.
- The touch control theme in the selected `OVERRIDES/<folder>/` directory is also bundled and appears first in the theme lists. For example, `OVERRIDES/ANIMAL WELL/theme.json` supplies the ANIMAL WELL theme.

The selected override theme is listed above CLASSIC; other bundled themes and imported themes follow. The selected override theme remains protected as a built-in theme.

## Installing a theme

1. Open the launcher and choose **Import touch controls theme**, or open the in-game control editor and choose **Import Theme…**.
2. Select the individual theme folder (for example, `CLASSIC`). You can also select this `TouchControlThemes` parent folder when it contains exactly one valid theme folder.
3. Choose the installed theme from **Control skin** in the launcher, or from the in-game editor's **Theme** menu.

The selected theme is saved and applied when the game starts.

## Creating a theme

Duplicate a theme folder and edit its `theme.json`. The six palette colors below are required; each must be a six-digit RGB hex string, with or without a leading `#`.

- `idle`
- `pressed`
- `outline`
- `ringFill`
- `text`
- `pressedText`

Button colors are optional and override the palette fill for that control. Supported button keys: A, B, X, Y, L, R, ZL, ZR, Stick, Minus, Plus, Dpad, and Layout.
