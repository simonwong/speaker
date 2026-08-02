# Logo Design Best Practices for Speaker

Last reviewed: 2026-08-02

This note translates first-party platform, trademark, and design-system guidance into constraints for Speaker, a macOS menu-bar voice-input product. It distinguishes sourced guidance from project-specific conclusions.

## Decision summary

- Stop iterating on the current waveform-plus-text-lines construction. It explains the category but does not provide an ownable core silhouette.
- Treat the brand mark, app icon, and menu-bar glyph as a family, not as one piece of geometry mechanically scaled into every context.
- Explore genuinely different concepts in solid black before applying the app-icon tile, color, material, shadow, or glass treatment.
- Design and inspect the menu-bar glyph directly in Speaker's actual 20×18 pt status frame and 18×14 pt padded drawing region, at both 1× and 2× raster output. Derive it from the winning brand idea, but simplify and optically correct it independently.
- Reject any concept that needs a verbal explanation, depends on effects, loses its identity in silhouette, or can be mistaken for a generic waveform, equalizer, microphone, text-alignment icon, or menu.

## Why the current direction fails

The current mark combines a waveform with horizontal lines intended to suggest transcription. WIPO explains that descriptive signs have little inherent trademark distinctiveness, while stronger marks distinguish a product from competitors and stand out from the crowd. Its selection checklist also recommends choosing a mark that is memorable across media and avoiding confusing similarity with existing marks. See [WIPO, *Making a Mark*, pp. 23–28](https://www.wipo.int/edocs/pubdocs/en/wipo-pub-900-1-en-making-a-mark-an-introduction-to-trademarks-for-small-and-medium-sized-enterprises.pdf).

Project-specific visual assessment, not a WIPO finding: Speaker's construction has no single dominant silhouette. The disconnected waveform and text-line components remain recognizable primarily as category cues, and the mark changes character when either group is removed. A competitor and similarity review is still required before concluding that the vocabulary is common in the market or that a future candidate is legally distinctive.

This does not mean a mark must be complicated. It means simplicity needs a distinctive idea. Apple describes an effective app icon as unique, memorable, expressive of the app's purpose and personality, and recognizable at a glance. Apple describes interface icons differently: they communicate a single concept with a highly simplified shape. See [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) and [Apple HIG: Icons](https://developer.apple.com/design/human-interface-guidelines/icons).

Project-specific conclusion: adding more waveform bends or more text lines moves the current design further toward a generic functional diagram, not toward a stronger identity.

## 1. Build one ownable core silhouette

Apple recommends a recognizable, highly simplified design for interface glyphs and a unique, memorable design for the app icon. Atlassian's first-party icon system similarly recommends the minimum detail required for a clear metaphor, warning that excess detail becomes difficult to understand at small sizes. WIPO adds that a strong mark must distinguish the source rather than merely describe the product.

For Speaker, a candidate should therefore have:

- one dominant silhouette;
- one memorable gesture, cut, or proportion that survives in solid black;
- a stable fill-or-stroke logic;
- enough negative space to remain separated after rasterization;
- no dependency on color, glass, gradient, shadow, or a surrounding tile for recognition.

The goal is not to make the mark arbitrary for its own sake. The core shape may suggest flow, speech, insertion, or the letter S, but it should not simply reproduce a category icon.

Sources: [Apple HIG: Icons](https://developer.apple.com/design/human-interface-guidelines/icons), [Atlassian Design System: Iconography](https://atlassian.design/foundations/iconography), and [WIPO: Trademark protection](https://www.wipo.int/en/web/trademarks/protection).

## 2. Separate brand identity from interface vocabulary

An app icon expresses identity and personality; an interface icon communicates an action, object, or state. Apple explicitly prohibits using SF Symbols, or confusingly similar images, in app icons, logos, or trademarked uses. A custom symbol may follow the system's optical conventions, but a stock microphone or waveform symbol is not a brand asset. See [Apple HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).

For Speaker:

- use familiar SF Symbols for ordinary menu commands such as Settings, History, Copy, Help, and Quit;
- use a custom brand mark for Speaker's identity;
- use a reduced custom status glyph for the menu-bar entry;
- do not force the brand mark into every control merely to increase logo exposure.

## 3. Create a responsive identity family, not one universal path

The same visual idea can require different geometry at different sizes. Google describes its compact G as a small-context derivative with increased visual weight and optical correction, not a mechanical reduction of the full logotype. Material Symbols exposes an optical-size axis because stroke thickness must change as symbols scale. Apple likewise calls for matching optical weight, alignment, position, detail, and scale in custom symbols.

Speaker needs at least two masters:

1. **Brand/app-icon master** — expressive enough to carry identity inside the app-icon presentation.
2. **Menu-bar master** — a monochrome, reduced, optically corrected glyph designed in the product's actual 20×18 pt status frame.

They must share recognizable visual DNA, but they do not need identical control points, gaps, or stroke weights.

Sources: [Google Design: Evolving the Google Identity](https://design.google/library/evolving-google-identity), [Google Developers: Material Symbols](https://developers.google.com/fonts/docs/material_symbols), and [Apple HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).

## 4. Design the menu-bar glyph at its real size

Apple's interface-icon guidance requires consistent visual weight, detail, scale, perspective, and optical alignment. IBM Carbon typically uses 16 px artboards and permits 20, 24, and 32 px icons for larger contexts; its 16 and 20 px icons are intended to balance with IBM Plex at corresponding text sizes. Atlassian designs its core icon set directly for a 16 px box and aligns stroke edges to the pixel grid for crispness. These dimensions belong to those systems and establish a method, not a macOS size requirement.

The Speaker status glyph should be reviewed in its current 20×18 pt frame and 18×14 pt padded drawing region, at 1× and 2× output, with:

- one-color black-and-transparent rendering;
- explicit whole-pixel or Retina-pixel alignment;
- no subpixel gaps that antialias into collisions;
- optical rather than merely mathematical centering;
- visual-weight comparison beside real macOS status icons;
- light, dark, highlighted, inactive, and increased-contrast appearances.

AppKit template images are black-and-clear artwork that the system processes for the surrounding appearance. The menu-bar glyph must not encode the app icon's ivory color, dark tile, gradient, shadow, or material. See [AppKit: `NSImage.isTemplate`](https://developer.apple.com/documentation/appkit/nsimage/istemplate), [Apple HIG: Icons](https://developer.apple.com/design/human-interface-guidelines/icons), [IBM Carbon: Icons](https://carbondesignsystem.com/elements/icons/usage/), and [Atlassian Design: Building the icon system](https://atlassian.design/whats-new/building-atlassians-new-icon-system/).

## 5. Design the app icon as an identity surface

Apple states that an app icon should express purpose and personality and stay recognizable across system appearances and sizes. Core visual features should remain consistent across default, dark, clear, and tinted appearances. The system scales the icon into smaller contexts, so fine features and fragile gaps are unsafe even when the 1024 px source looks polished.

For Speaker, first approve the mark without a container. Only then evaluate:

- rounded-square composition and safe visual margins;
- default, dark, clear, tinted, and monochrome appearances;
- 32, 64, 128, and 1024 px rasterizations;
- whether material and color support the mark without becoming its only identity.

Source: [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons).

## 6. Use negative space for separation, not cleverness

Negative space is useful when it strengthens the silhouette, preserves clearance, or creates a memorable secondary reading. It is harmful when the idea appears only after explanation or disappears at small sizes. Official systems emphasize optical balance, clear space, minimal detail, and consistent geometry rather than decorative tricks.

Speaker candidates should pass these checks:

- Does the negative space remain open in the actual 18×14 pt drawing region at 1× and 2×?
- Is the primary silhouette recognizable before the secondary reading is noticed?
- Does the mark still work as a filled black shape?
- Does removal of the surrounding tile leave a complete identity?

Sources: [Apple HIG: Icons](https://developer.apple.com/design/human-interface-guidelines/icons), [Atlassian Design System: Logos](https://atlassian.design/foundations/logos), and [IBM Carbon: Icons](https://carbondesignsystem.com/elements/icons/usage/).

## Speaker concept brief

The following is a project-specific brief derived from the research.

### Desired character

- calm, precise, immediate, and warm;
- native to macOS without imitating Apple artwork;
- more like a trusted input instrument than an audio player;
- recognizable without the word Speaker.

### Avoid

- generic microphone silhouettes;
- raw waveform or equalizer graphics;
- speech bubbles combined with text lines;
- three disconnected horizontal strokes;
- an unmodified letter S;
- play, record, broadcast, or menu metaphors;
- complexity introduced only to look unique.

### Promising territories to explore

These are territories, not finished visual prescriptions:

- a custom S-derived silhouette with a proprietary cut or counterform;
- a single gesture that suggests speech entering an insertion point;
- an abstract input mark whose negative space implies voice or text without drawing either literally;
- a compact monogram whose status-glyph derivative can survive as one or two masses.

## Candidate review process

1. Produce 6–12 genuinely different black-and-white concepts. Do not generate spacing variants of one waveform.
2. Remove names, tiles, colors, and effects. Reject concepts without a distinctive core silhouette.
3. Render every app-icon candidate at 32, 64, 128, and 1024 px. Render every status-glyph candidate in Speaker's 20×18 pt frame at 1× and 2×.
4. Reject concepts whose gaps close, strokes merge, or identity changes at any required size.
5. Place the 20×18 pt status variant beside actual macOS status icons and compare weight and optical centering.
6. Conduct a brief unlabelled recall test: show each candidate for a few seconds, then ask what shape was remembered and what existing product it resembles.
7. Compare finalists with direct competitors and visually similar trademarks. WIPO recommends an availability search before adoption; use the [WIPO Global Brand Database](https://branddb.wipo.int/) as one input, not as a substitute for legal clearance.
8. Have a separate reviewer score distinctiveness, reduction, small-size performance, platform fit, and consistency.
9. Select the core idea first. Redraw the app-icon and menu-bar masters separately.
10. Only after the geometry is approved, add color, app-icon material, and production assets.

## Acceptance rubric

| Criterion | Pass condition |
| --- | --- |
| Distinctiveness | Does not look like a stock mic, waveform, equalizer, text, menu, or generic S icon |
| Recall | A reviewer can redraw the primary silhouette after a brief exposure |
| Reduction | Remains recognizable in solid black in Speaker's 20×18 pt status frame at 1× and 2× |
| Geometry | Uses coherent weight, terminals, radii, gaps, and optical balance |
| Responsiveness | App icon and status glyph clearly belong together without sharing fragile geometry |
| Independence | Works without color, tile, gradient, shadow, glass, or explanatory copy |
| Platform fit | Status glyph behaves as a macOS template image; app icon follows Apple appearance requirements |
| Collision risk | No close match is found among direct competitors or an initial trademark search |

## Primary sources

- [Apple Human Interface Guidelines: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple Human Interface Guidelines: Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [Apple Human Interface Guidelines: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Apple AppKit: `NSImage.isTemplate`](https://developer.apple.com/documentation/appkit/nsimage/istemplate)
- [WIPO: *Making a Mark*](https://www.wipo.int/edocs/pubdocs/en/wipo-pub-900-1-en-making-a-mark-an-introduction-to-trademarks-for-small-and-medium-sized-enterprises.pdf)
- [WIPO: Trademark protection](https://www.wipo.int/en/web/trademarks/protection)
- [WIPO Global Brand Database](https://branddb.wipo.int/)
- [Google Design: Evolving the Google Identity](https://design.google/library/evolving-google-identity)
- [Google Developers: Material Symbols](https://developers.google.com/fonts/docs/material_symbols)
- [IBM Carbon Design System: Icons](https://carbondesignsystem.com/elements/icons/usage/)
- [Atlassian Design System: Iconography](https://atlassian.design/foundations/iconography)
- [Atlassian Design System: Logos](https://atlassian.design/foundations/logos)
