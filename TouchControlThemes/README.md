# Touch Control Themes

Themes can be bundled into the IPA or imported by the user. The IPA workflow lets you choose which built-in themes to include; ANIMAL WELL and CLASSIC are enabled by default, while FOREST is optional and disabled by default.

## Built-in themes

- `ANIMAL WELL` — the default touch control theme.
- `CLASSIC` — the brighter neutral-gray theme.
- `FOREST` — the restored forest-green theme with gold accents.

Only the themes selected in the Run workflow menu are bundled. Other themes can still be imported by the user.

## Installing a theme

1. Open the launcher and choose **Import touch controls theme**, or open the in-game control editor and choose **Import Theme…**.
2. Select the individual theme folder (for example, `Forest`). You can also select this `TouchControlThemes` parent folder when it contains exactly one valid theme folder.
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
