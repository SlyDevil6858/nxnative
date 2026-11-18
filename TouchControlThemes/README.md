# Touch Control Themes

Themes can be bundled into the IPA or imported by the user.

## Built-in themes

- `ANIMAL WELL` — the default touch control theme. Its `theme.json` lives in `OVERRIDES/ANIMAL WELL/` alongside that game's icon and launcher background; it is bundled independently of the optional theme selections.
- `CLASSIC` — the brighter neutral-gray theme.

The Run workflow menu controls whether CLASSIC is bundled. ANIMAL WELL is always bundled from its game-specific override folder. Other themes can still be imported by the user.

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
