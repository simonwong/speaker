# Speaker Design System

One visual language for the main window, onboarding, menu bar, banners, and dialogs. The HUD shares the type roles but keeps its own palette. Tokens and components live in `Sources/SpeakerAppFeatures/DesignSystem/`; page code uses them and never writes raw numbers, fonts, or status colors.

## Principles

- Fewer words. A row says what it is and its value or state; it does not explain its purpose. Keep privacy promises, actionable errors, consent text, and onboarding instructions.
- Liquid Glass stays: cards, fields, and buttons use the adaptive glass style (glass → system material → opaque under Reduce Transparency). Fix readability, never replace glass with paper.
- Coral (`controlTint`) marks only a prominent submit button, a switch, progress, a selection, or a focused field. Every other control is neutral. Gold marks secondary brand detail, "editing, not yet in use", the dictionary capacity bar, and refinement pending in the HUD.
- Status color comes from `SpeakerTone`, never from a `Color` literal.

## Tokens

### Type (`SpeakerTypography`)

| Role | Font | Use |
|---|---|---|
| `title` | title2 semibold (17) | identity or step title: About's "Speaker", onboarding step titles |
| `label` | callout semibold (12) | section headers, history day headers, small bold labels |
| `emphasis` | body medium (13) | row titles, chip text, keycap (+ `.fontDesign(.rounded)`) |
| `body` | body (13) | content, field text, history text |
| `detail` | callout (12) | every secondary line: row detail, notices, badges, counts, legends |
| `mono` | callout monospaced medium (12) | request IDs, history time column |
| `Display.metric` / `Display.hero(size:)` | serif digits | Overview numbers only |

Only `.monospacedDigit()` may follow a token. No `.weight(...)` on a token, no `.system(size:)` outside Brand and HUD.

### Spacing (`SpeakerSpacing`)

`hairline 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`

- Page: top `xl`, bottom `xxl`, content column max width 720, centered.
- Between settings groups `xxl`; section header to card `s`; between cards in one group `l`.
- Card padding `l`; rows inside a card separated by `SpeakerRowDivider`; icon tile to text `m`; controls in one trailing group `s`.

### Shape (`SpeakerRadius`)

- `card` 12: glass cards, onboarding cards.
- `inner` 8: rectangles inside a card: notices, multiline editors, mode cards, history and custom-mode rows, keycap, icon tiles.
- `Capsule()`: every 28-pt interactive control: buttons, menus, single-line fields, chips, tab selection, progress tracks.
- `Circle()`: icon-button hover background.
- Heatmap cells keep local values.

### Size (`SpeakerControlMetrics`)

- `height` 28: buttons, menus, fields, search, keycap, chip, icon-button hit area. Every control in one row has this height.
- `compactHeight` 20: only a button inside a 28-pt control (chip delete).
- `rowMinHeight` 36 for `SpeakerRow`; `trailingWidth` 260.
- No `.controlSize(.small)` on buttons.

### Color

- Text: `.primary`, `.secondary`, `.tertiary` only (HUD excepted).
- `SpeakerTone`: `neutral` (secondary, `info.circle.fill`), `ok` (`settledGreen`, `checkmark.circle.fill`), `warning` (orange, `exclamationmark.circle.fill`), `error` (red, `xmark.circle.fill`).
- `SpeakerFill`: `subtle` 0.04 (neutral notice, hover), `control` 0.06 (keycap, chip, icon tile, glass-button underlay, track), `selected` 0.10 (tab selection, expanded row, icon-button hover), `tone(_:)` 0.07 / 0.16 increased contrast.
- `SpeakerStroke`: `hairline` primary 0.10 / 0.40 increased contrast; `focus` controlTint 0.7 at 1.5 pt (focused field, recording keycap).
- No `Color.accentColor`, no system `.green`.

## Components

| Component | Rule |
|---|---|
| `SpeakerPage` / `.speakerPageColumn()` | The only place the content column is defined. No page title: the tab bar names the page. |
| `SpeakerSectionHeader` | The only group heading. Outside the card, `label`, secondary, inset 4 so it aligns with the card's corner curve. Never red. |
| `SpeakerCard` | Glass card holding settings the user changes. No title or icon inside it. Collections (history records, dictionary entries, Overview figures) sit on the page ground, not in a card. |
| `SpeakerRow` | Optional icon tile, title (`emphasis`), optional detail (`detail`, secondary; a value or state, not an explanation), trailing controls. Icon tiles only on rows that stand for a system object with a status: Permissions (Settings and onboarding). |
| `SpeakerRowDivider` | Between rows inside a card only. |
| `StatusBadge(tone:)` | All row status. Settled tones (`neutral`, `ok`) render secondary text. |
| `SpeakerNotice(tone:text:action:onDismiss:)` | The one inline message: settings notices, setup banner, what's-new banner, Fn conflict hint, recorder rejection, history/dictionary feedback. Radius `inner`, padding 12/8, `fill.subtle` or `fill.tone`. Its action button lives inside it, trailing. Only the setup banner's action may be prominent. |
| `SpeakerButtonStyle` | Neutral glass capsule or prominent coral, 28 pt. At most one prominent per card, only for submitting what the user just entered. Navigation and external links are neutral. Prominent keeps the `fill.control` underlay so a disabled one stays visible. Destructive: neutral button with red text; the scope goes in the confirmation dialog. In-app actions are buttons, never link-styled text. |
| `SpeakerIconButton(symbol:label:size:)` | All icon-only buttons: 28 regular, 20 compact; hover circle, `help`, accessibility label. |
| `SpeakerKeycap` | 28 high, radius `inner`, `emphasis` rounded, min width 56; recording state uses `SpeakerStroke.focus` with secondary text. |
| `SpeakerChip` | Single-line capsule, 28 high. Omitted entry: orange hairline and a leading `exclamationmark.circle.fill`. Quality hint: a trailing secondary glyph; the text goes to `.help` and the accessibility label. |
| `SpeakerLink` | External URLs only: secondary text + `arrow.up.right`. |
| `SpeakerEmptyState` | Empty states inside the window; description optional. `ContentUnavailableView` only for whole-window states. |
| `.speakerSwitch()` / `.speakerProgress()` | Switches and progress get `controlTint` here only. |
| Dialogs | `.confirmationDialog` for every confirmation; destructive button role; shared copy constants. |

## Surfaces that differ on purpose

- HUD: always dark glass, `.circular` corners, its own stroke, shadow, and contrast palette (`HUDPalette`). Its prominent buttons are solid white/black circles. Coral only on level bars; gold only while refinement is pending. Type maps to `body`/`detail`/`label` sizes. UI specs pixel-check the HUD border and corners.
- Menu bar: monochrome template icon; native menu. Every item except Quit has an SF Symbol; a setup gap uses `exclamationmark.triangle`.
- Onboarding: same cards, rows, notices, and buttons as the main window; window title text hidden because each step shows its own `title`.
- Brand marks and the Overview heatmap keep local drawing constants.

## Guarding

`scripts/check-design-tokens`, part of `./scripts/test`, fails when page code outside `DesignSystem/`, `Brand/`, and `VoiceInputHUD*.swift` contains `.system(size:`, `Color.accentColor`, `cornerRadius: <number>`, `.green`, or a non-zero `spacing: <number>` / `.padding(<number>)`. `spacing: 0` and 1-pt hairline frames stay allowed.
