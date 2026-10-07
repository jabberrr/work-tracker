# Worklog — Design (docs/DESIGN.md)

> Owner: **DES**. This is the design language and the screen-by-screen UX spec for feature programmers
> **A** (live session, end-session sheet, menu bar, overlay), **B** (history, session detail, learnings
> editor) and **C** (learning, stats, settings, welcome). The API contract is `docs/ARCHITECTURE.md` §4;
> this document says **how to use it**. Where the two disagree on a signature, ARCHITECTURE.md wins.

Code lives in `Worklog/DesignSystem/**` and `Worklog/Shared/**`. Read the theme with
`@Environment(\.theme) private var theme`. **Never hard-code a color, font, radius or spacing.** The only
exception is a label's or tag's own color, which you get from `label.color` / `tag.color` (or `ColorDot(hex:)`).

---

## 1. Principles

1. **It sits beside real work for hours.** Calm, low-chroma surfaces; one accent; nothing blinks, bounces or
   nags. The busiest thing on screen should be the user's own text.
2. **Typography does the work.** Hierarchy comes from size, weight and face, not from boxes, gradients or
   color. Use cards only to group things that belong together; prefer whitespace and hairline rules.
3. **The timer is an instrument.** Tabular (monospaced) digits everywhere a duration appears, so numbers
   never jitter. The hero timer is large, light-weight and quiet. Running vs. paused is shown by color *and*
   a word/glyph ("Paused", `LiveDot`).
4. **Native first.** System materials and vibrancy for the menu bar panel and overlay; native `Picker`,
   `Toggle`, `DatePicker`, `Form`, `Table`/`List`, sheets, popovers, alerts and `confirmationDialog`.
   Custom only where it adds character: timers, badges, chips, cards, buttons, empty states.
5. **Not an "AI app".** No cream/beige backgrounds with terracotta accents, no serif-on-paper "editorial
   assistant" default, no soft multicolor gradient cards, no glow, no emoji in UI chrome, no sparkles.
   The default is a crisp, neutral, sans-serif tool (Graphite); Paper and Meadow are opt-in alternatives.
6. **Every style is a theme.** All three themes work in light and dark appearance, and a fourth is one enum
   case plus one factory (§15).

---

## 2. Themes

Selected in Settings → Appearance (`ThemeManager.themeID`) or on the Welcome screen (`ThemeSwatchRow`),
combined with appearance mode (System / Light / Dark) and an accent override (`AccentChoice`).
Default: **Graphite** (`ThemeID.default`), System, Theme Default accent. Pickers list themes in
`ThemeID.allCases` order: Graphite, Paper, Meadow.

**Brief check (all three):** simple (one accent, one display face, no gradients), pleasing (tuned contrast,
calm chroma), unintrusive (no motion or color that competes with the user's text), distinct from each other
(sans/mono · serif · rounded) and not generic (each has one signature: Graphite's mono readouts and ruled
legends, Paper's serif numerals, Meadow's soft depth). None uses the cream + terracotta + serif combination
typical of AI-assistant apps; Paper keeps serif type but on neutral white with a blue ink accent.

### 2.1 Graphite — a precise instrument (default)
- **Look (light):** crisp and neutral — white cards (`#FFFFFF`) on a barely-grey ground (`#F6F7F8`), sidebar
  `#EEF0F2`, cool hairlines (`#DADDE1`), near-black text (`#15171A`). One **teal signal** accent
  (`#0B6C78`, 6.1:1 on white) that the running timer also uses. Paused readouts turn amber (`#8A5700`).
- **Look (dark):** near-black anodised panels (`#121315`, cards `#1A1C1F`), accent `#35C6D4`.
- **Type:** SF Pro for all running text, titles and chips. SF Mono (`.monospaced`) only for **readouts**:
  timers and the small section legends, which are `UPPERCASE`, tracked, secondary-colored, on a rule.
- **Shape:** tight radii (3/5/8), 1 pt hairline borders, no shadows. **Solid panels**
  (`usesMaterials == false`): the overlay and menu bar panel use `elevatedSurface` for deterministic contrast.
- **Why default:** the least decorated and most neutral option; reads as a precise tool, not a
  document or a chat app. The mono readouts give it character without color or ornament.

### 2.2 Paper — editorial, ink on paper
- **Look:** near-white *neutral* paper (`#FBFBFA`, not cream), blue-black ink text (`#15171A`), a
  fountain-pen blue accent (`#2C44B8`). Dark: charcoal reading-mode (`#141517`) with soft white ink and a
  periwinkle accent (`#93A6FF`).
- **Type:** New York (`.serif`) for large titles, titles, section headers **and the timers**; SF Pro for
  running text. The hero timer is a light serif numeral — like a printed figure.
- **Shape:** small radii (4/6/10), 1 pt hairline borders, **no shadows**. Section headers sit on a hairline
  rule that runs to the trailing edge, like a printed page.
- **Running timer** is ink (`textPrimary`-like), not accent: the accent is reserved for actions.
- **Why:** for people who like a "document-like" journal; serif display gives character without color.
  Kept as an option, not the default (serif-on-paper is the look the brief asked to avoid by default).

### 2.3 Meadow — soft natural green
- **Look:** pale sage (`#F3F6F2`) with off-white cards; deep forest in dark (`#111612`). Moss-green accent
  (`#346E4E` / `#7DC79B`). Running timer in deep forest green (light) / pale mint (dark).
- **Type:** SF Pro Rounded (`.rounded`) for display, section headers, chips and timers; SF Pro for text.
- **Shape:** generous radii (6/12/18), **borderless** cards lifted by a very soft shadow, capsule chips,
  translucent panels (`.regular` material).
- **Why:** the gentlest option for long days; friendly without being cute.

### 2.4 Light and dark
Each factory branches on `ColorScheme`. Never "invert" a theme in feature code: always read the token.
Appearance mode is applied app-wide via `NSApp.appearance` (`ThemeManager.applyAppearance()`), so sheets,
popovers, the menu bar panel and the overlay all follow.

### 2.5 Accent override
`AccentChoice` (Blue, Purple, Pink, Red, Orange, Yellow, Green, Graphite) replaces `theme.accent` with the
dynamic system color. `onAccent` becomes near-black for Orange/Yellow/Green/Graphite (white fails contrast
there), white otherwise. In Graphite the running timer follows the accent. Label colors are unaffected.

---

## 3. Color roles

| Token | Use for | Never use for |
|---|---|---|
| `background` | Main window content area (via `themedBackground()`) | Cards |
| `sidebarBackground` | Sidebar (`themedBackground(.sidebar)`) | — |
| `surface` | Cards, StatTiles, list rows that need a fill, banners' base | Whole panes |
| `elevatedSurface` | Sheets, popovers, overlay/menu panel fill when `!usesMaterials` | Cards in a pane |
| `insetSurface` | Text fields, note composer, wells, tag chips | Buttons |
| `textPrimary` | Titles, body, values | Disabled text |
| `textSecondary` | Supporting text, metadata, section labels (Graphite) | Long body text |
| `textTertiary` | Timestamps, captions, placeholder-ish hints, inactive icons | Anything essential |
| `accent` | The primary action, selection, focus ring, links, "Show more" | Decoration, large fills |
| `onAccent` | Text/icons on an accent fill | — |
| `separator` | Hairlines, borders, rules, chip outlines | Text |
| `success` / `warning` / `danger` | Banners, destructive buttons, status icons | Label colors |
| `timerRunning` / `timerPaused` | Timer digits (TimerText does this) and LiveDot | Other text |
| `chartPalette` | Chart series **without** a label color (tags, weekdays…) — `theme.chartColor(i)` | UI chrome |

Rules:
- **Tints:** to tint a background with a label or status color, use `color.opacity(theme.tintOpacity)`
  (≈0.10–0.18 depending on theme/scheme). Never put a saturated label color behind text.
- **Label colors** are for identification (dots, badge icons, chart series, segment strips). Text stays
  `textPrimary`; color is never the only signal (badges always show the name).
- **One accent per region.** A view has at most one `PrimaryButtonStyle` button.

---

## 4. Typography

Base sizes at text size *Standard* (macOS body = 13 pt). All fonts scale with the extra
`ThemeManager.textSize` (Small 0.92 · Standard 1.0 · Large 1.12 · Extra Large 1.25) — this is the app's
"Dynamic Type". `worklogThemed` sets `theme.bodyFont` as the default font, so unstyled `Text` and native
controls scale too. When you need a custom size (rare), multiply by `theme.textScale`.

| Token | Size | Paper | Graphite | Meadow | Use |
|---|---|---|---|---|---|
| `largeTitleFont` | 28 | New York Medium | SF Pro Semibold | Rounded Semibold | Page titles ("Today", "History") |
| `titleFont` | 20 | New York Medium | SF Pro Semibold | Rounded Semibold | Session title in detail, sheet titles, empty-state titles |
| `sectionHeaderFont`* | 15 / 10.5 / 14 | New York Semibold | SF Mono Semibold, UPPERCASE | Rounded Semibold | `SectionHeader` only |
| `headlineFont` | 13 semibold | SF Pro | SF Pro | SF Pro | Row titles, card titles |
| `bodyFont` | 13 | SF Pro | SF Pro | SF Pro | Notes, learnings, fields |
| `calloutFont` | 12 | SF Pro | SF Pro | SF Pro | Secondary lines, banners, messages |
| `captionFont` | 11 | SF Pro | SF Pro | SF Pro | Timestamps, metadata, chart axes |
| `labelFont` | 11 medium | SF Pro | SF Pro | Rounded | Chips, badges |
| `monoFont` | 12 | SF Mono | SF Mono | SF Mono | IDs, file sizes, keyboard hints |
| `timerHeroFont` | 68 / 60 / 64 light | New York | SF Mono | Rounded | Today hero timer |
| `timerFont` | 34 / 30 / 32 | New York | SF Mono | Rounded | Overlay, menu bar panel |
| `timerMediumFont`* | 20 | ″ | ″ | ″ | Current-segment timer, live row in History |
| `timerCompactFont` | 13 medium | ″ | ″ | ″ | Rows, compact overlay, sidebar status |
| `displayNumberFont`* | 22 | display face | display face | display face | StatTile values, today total |

\* = extra token (beyond the contract).

Rules:
- Every duration uses `TimerText` or a timer font, and `.monospacedDigit()` if you format it yourself.
- Use `TimeInterval.formattedShort` ("1h 05m") for totals in prose and `formattedClock` for live clocks.
- Line length: cap reading columns (notes, learnings, detail) at ~680 pt with `.frame(maxWidth: 680)`.
- Truncate titles with `.lineLimit(1)` + tail; notes use `lineLimit(6)` with "Show more" (NoteRow does it).

---

## 5. Spacing, radius, elevation

Spacing tokens: `spacingXS 4 · S 8 · M 12 · L 16 · XL 24 · XXL 32` (same in all themes).

| Context | Value |
|---|---|
| Pane padding (main window detail) | `spacingXL` horizontal, `spacingXL` top |
| Between sections in a pane | `spacingXL` (Paper/Graphite) — use `spacingXXL` before a page-level break |
| Inside a card | `spacingL` (Card default) — `spacingM` for dense cards |
| Between rows in a list of cards | `spacingS` |
| Label + value pairs | `spacingXS` |
| Menu bar panel / overlay padding | `spacingL` / `spacingM` (compact overlay) |

Radius tokens: `radiusS` (fields, buttons, chips in Paper/Graphite), `radiusM` (cards, banners),
`radiusL` (overlay panel, large thumbnails). Chips/badges use `theme.chipShape` (capsule in Meadow).

Elevation: only Meadow uses shadows (cards: `shadowColor/Radius/Y`). Paper and Graphite separate planes
with `separator` hairlines. Never add your own `.shadow`.

---

## 6. Iconography (SF Symbols)

Monochrome/hierarchical, `.medium` weight in buttons, `textSecondary` at rest. Labels carry their own
symbol (`label.symbolName`). Standard symbols — use these so the app speaks one language:

| Concept | Symbol | Concept | Symbol |
|---|---|---|---|
| Start | `play.fill` | Pause / Resume | `pause.fill` / `play.fill` |
| Stop | `stop.fill` | Split segment | `scissors` |
| Discard | `trash` | Add note | `square.and.pencil` |
| Notes | `note.text` | Attach image | `photo.badge.plus` (`photo` for section) |
| Segments | `rectangle.split.3x1` | Learnings | `lightbulb` |
| Takeaway | `quote.opening` | Tags | `number` |
| Label (none) | `circle.dashed` | Today total / goal | `target` |
| History | `clock.arrow.circlepath` | Stats | `chart.bar.xaxis` |
| Search | `magnifyingglass` | Sort | `arrow.up.arrow.down` |
| Filter | `line.3.horizontal.decrease` | Overlay | `rectangle.inset.topright.filled` |
| Open main window | `macwindow` | Settings | `gearshape` |
| Close / dismiss | `xmark` | Edit time | `clock.badge.checkmark` |
| Merge segments | `arrow.triangle.merge` | Move boundary | `arrow.left.and.right` |
| iCloud on / off | `icloud` / `icloud.slash` | Backup | `externaldrive` |
| Export / Import | `square.and.arrow.up` / `square.and.arrow.down` | Account | `person.crop.circle` |
| Mastery (rated) | `circle.fill` ×1–5 | Mastery (empty) | `circle` |

Menu bar label (A): `timer` idle, `record.circle` running, `pause.circle` paused (contract §5.3).

### 6.1 App icon (`Assets.xcassets/AppIcon.appiconset`)

A **segmented session dial**: a flat graphite tile (`#1A1D21`, standard macOS 824/1024 rounded-square grid,
hairline inner edge, soft system-style drop shadow, no gradient) carrying a ring track (`#2A2E34`) with
three work segments separated by gaps — teal `#35C6D4` (the Graphite accent, leading from 12 o'clock),
off-white `#E6E8EB`, amber `#D9A441` — a short stopwatch crown above 12 o'clock and a teal live dot in the
centre. It reads as "a timer split into segments", the app's core idea, and stays legible at 16 px (the
16/32 px renders use 25 % heavier strokes). PNGs for all ten mac slots (16–512 @1x/@2x) are rendered
programmatically at 4× supersampling (Pillow) and downscaled with Lanczos; to change the icon, regenerate
all ten sizes together rather than editing single PNGs by hand.

---

## 7. Motion

- Default: **none or very short**. Hover fades 120 ms ease-out; press 80 ms. Sheets/popovers: system.
- Allowed: `LiveDot` breathing (1.6 s ease-in-out, opacity 1 → 0.45), cross-fade when switching
  idle ⇄ active on Today (`.transition(.opacity)`, 200 ms), expanding a note (no animation needed).
- Not allowed: counting/rolling digits on the timer, bouncing, springy scale, confetti, parallax.
- **Reduce Motion:** read `@Environment(\.accessibilityReduceMotion)`; pass `nil` animation when true.
  Design-system components already do.

---

## 8. Components (DesignSystem)

All inits are exactly as in ARCHITECTURE.md §4.6. Usage is explicit: `.buttonStyle(PrimaryButtonStyle())`.

| Component | Guidance |
|---|---|
| `Card(padding:) { … }` | Groups related content; fills width, leading-aligned. `cardStyle()` for an existing view. Don't nest cards. |
| `SectionHeader(_:systemImage:trailing:)` | One per section. Trailing: a count (`Text("3")`), an `IconButtonStyle` button or a small `Menu`. Themes render it differently (rule / uppercase). |
| `LabelBadge(label:size:)` | Anywhere a label is shown. `.small` in rows, `.regular` default, `.large` for the Today active header. |
| `TagChip(tag:isSelected:onRemove:)` | Single tag. Dot appears only for tags with a non-default color. |
| `ColorDot(hex:size:)` | Decorative dot; pair with text. |
| `TimerText(_:style:isPaused:)` | Pure display. Wrap in `TimelineView(.periodic(from: .now, by: 1))` when running; render statically when paused. |
| `PrimaryButtonStyle` | The one primary action (Start, Save, Create). Add `.keyboardShortcut(.defaultAction)` where it's the default. |
| `QuietButtonStyle` | Secondary actions (Pause, Split, Cancel, Attach, Restore…). |
| `DestructiveButtonStyle` | Discard / Delete. Always followed by a confirmation (`confirmationDialog`). |
| `IconButtonStyle(size:)` | Icon-only (toolbar-like) buttons; 28 default, 22 in dense rows, 20 in banners. Always `.accessibilityLabel` + `.help`. |
| `EmptyStateView(…)` | Whole-pane empty states (copy in §12). |
| `SearchField(text:prompt:)` | History, Learning, popovers. ⌘F → use the extra `init(text:prompt:isFocused:)`. |
| `StatTile(…)` | Stats and Today totals, in an adaptive grid (min 150). |
| `FlowLayout(spacing:lineSpacing:)` | Wrapping chips and swatches. |
| `InlineBanner(…)` | Top-of-pane notices (storage mode, auto-pause, long session, errors). Max two stacked. |
| `ThemePreviewSwatch(themeID:isSelected:compact:)` | Appearance tab (`compact: false`, default: light + dark halves, name + summary, 196 pt); Welcome (`compact: true`: one preview in the current appearance, name only, summary as tooltip, 124 pt). Wrap in a `.plain` Button — or use `ThemeSwatchRow`. |
| `ThemeSwatchRow(compact:)` | Extra. One swatch per `ThemeID` that sets `ThemeManager.themeID` on click (reads `ThemeManager` from the environment; renders nothing without it). Default `compact: true` ≈ 396 pt wide — Welcome screen. |

**Extras (beyond the contract) — available to all features:**

| Extra | Signature / purpose |
|---|---|
| `LiveDot` | `LiveDot(isPaused: Bool, size: CGFloat = 8)` — running dot (breathing) / pause glyph, labelled for VoiceOver. Use next to every live timer outside the hero. |
| `ProportionBar` | `ProportionBar(parts: [ProportionBar.Part], total: Double? = nil, height: CGFloat = 6)`, `Part(value:color:label:)` — segment strips, History row timelines, goal meters (`total:` = goal). |
| `View.themedPanelBackground(cornerRadius:)` | Material (or `elevatedSurface` when `!theme.usesMaterials`) panel fill. Overlay: `cornerRadius: theme.radiusL`; menu bar panel: `nil`. |
| `View.insetField(isFocused:)` | Inset well styling for `TextField(...).textFieldStyle(.plain)` (note composer, quick note, titles). |
| `CardSurfaceModifier(padding:)` | The modifier behind `Card`/`cardStyle()` with custom padding. |
| `Theme` extras | `sectionHeaderFont`, `timerMediumFont`, `displayNumberFont`, `chipShape`, `chipRadius`, `tintOpacity`, `textScale`, `timerUsesAccent`, `sectionHeaderUppercased/Ruled`, `fontRecipe`, `isDark`, `color(for: SurfaceLevel)`, `chartColor(_ index:)`, `applyFonts(scale:)`, `applyAccent(_:)`, `Theme.make(_:colorScheme:accent:textSize:)`. |
| `ThemeManager.textSize` | `ThemeTextSize` (`.small/.standard/.large/.extraLarge`, `displayName`, `scale`), key `"appearance.textSize"`; `resetToDefaults()`. |
| `ThemeID.systemImage`, `AppearanceMode.systemImage`, `AccentChoice.nsColor`, `AccentChoice.prefersDarkForeground` | Small helpers for Settings. |
| `LabelPalette.swatches` (`[LabelSwatch]` name+hex), `name(forHex:)`, `normalized(_:)`, `accessibilityName(forSymbol:)`, `defaultTagHex` | Palette helpers. |
| `WorkTag.hasCustomColor` | False for the default gray (and for a deleted tag). |
| `ModelLiveness.isLive(_:)`, `.live(_ model:)`, `.live(_ models:)` | Is a SwiftData model still readable (`!isDeleted && modelContext != nil`)? Use before reading a label/tag/note a view may still hold after it was deleted or merged (e.g. `@State var startLabel`). Shared controls, `LabelBadge`, `TagChip`, `label.color`/`tag.color` already guard. |
| `LabelMenuIcon.image(symbol:hex:pointSize:)` / `.dot(color:diameter:)` | Colored non-template `NSImage`s for native menus (`Image(nsImage:)`), e.g. A's Split menu. |
| `DesignSystemDurationSpeech.spoken(_:)` | "1 hour, 5 minutes" for `.accessibilityValue` on custom duration displays. |

## 9. Shared data-bound controls (`Worklog/Shared`)

| Control | Behavior |
|---|---|
| `LabelPicker(selection:includeNone:title:)` | Native pop-up `Picker` (`.menu`): "None", divider, non-archived labels by `sortIndex` with colored symbol; an archived current selection is listed as "Name (archived)". Shows its `title` on the left; use `.labelsHidden()` in compact places. |
| `TagPicker(selection:scopeLabel:allowsCreate:)` | Selected tags as removable chips + a dashed "+ Add tag" chip that opens a popover: search field (focused), **scope label's tags**, **Global**, and while searching **Other labels**; rows toggle (multi-select, popover stays open); "Create “x” ⏎" creates a *global* tag via `TaxonomyOps.createTag(name:in:)` and selects it. Return = toggle exact/only match or create. Bind with `$session.tagList`, `$segment.tagList`, `$point.tagList`. The picker does not call `touch()`. |
| `TagChipsRow(tags:)` | Read-only chips; renders nothing when empty. |
| `NoteRow(note:showsSegment:)` | `10:42` (caption, tabular, tertiary) · selectable body text (6 lines + "Show more") · optional segment caption (dot + focus) · "Edited". Read-only; add `.contextMenu` (Edit / Change time / Delete) in your feature. |

**Deleted models.** A label or tag can be deleted or merged in Settings while another view still holds it
(Today's start label in `@State`, the menu bar picker, an open editor). Reading such a model traps, so:
`LabelPicker` treats a deleted selection as nil, `TagPicker` drops deleted tags — both never read them,
never offer them, and write the cleaned value back to the binding (on appear and whenever the label/tag
list changes). `TagChipsRow`, `TagChip`, `LabelBadge` (→ "Unlabeled") and `NoteRow` (renders nothing for a
deleted note; skips a deleted segment/label) also guard. Feature code that reads a held model outside these
controls checks `ModelLiveness.isLive(_:)` first.
| `LabelColorPicker(hex:)` | 15 swatches (wrapping) + system color well for custom; selected ring. |
| `SymbolPicker(symbolName:)` | Adaptive grid (30 pt cells) of `LabelPalette.symbols`; current custom symbol shown first. Put it in a popover or a fixed-height area (~240 pt). |

---

## 10. Screens

Wireframes are schematic (not to scale). `[ Primary ]` = PrimaryButtonStyle, `( Quiet )` = QuietButtonStyle,
`{!Danger}` = DestructiveButtonStyle, `⊡` = IconButtonStyle, `▾` = native pop-up/menu, `◉` = LabelBadge,
`#tag` = TagChip, `●` = LiveDot. Every pane: `themedBackground()` on the root, padding `spacingXL`,
content column `maxWidth ≈ 760` centered unless stated.

### 10.1 Main window shell (CORE, for reference)

```
┌──────────────┬──────────────────────────────────────────────────────────────┐
│ ◷ Today      │  [InlineBanner: Saving to this Mac only …              ✕]    │
│ ↺ History    │                                                              │
│ ✧ Learning   │                    (detail pane — §10.2…)                    │
│ ▥ Stats      │                                                              │
│              │                                                              │
│ ● 1:12:40    │                                                              │
│   Deep work  │                                                              │
│──────────────│                                                              │
│ Guest     ⚙  │                                                              │
└──────────────┴──────────────────────────────────────────────────────────────┘
```
Sidebar status row: `LiveDot` + `TimerText(.compact)` + label name (`captionFont`, `textSecondary`).
(Glyphs in diagrams stand for SF Symbols; the UI never uses emoji.)

### 10.2 Today — idle (A: `LiveSessionView`)

```
  Today                                              Wednesday, Oct 7      ← largeTitle + caption
  ─────────────────────────────────────────────────────────────────────
  ┌ Card ───────────────────────────────────────────────────────────────┐
  │  What are you working on?                         ← headlineFont      │
  │  [ Focus (optional) _______________________________________ ]        │
  │  Label ▾ ◉ Deep work        #coding  #review  (+ Add tag)            │
  │                                                  [ ▶ Start session ]  │
  └─────────────────────────────────────────────────────────────────────┘

  ┌ Card ─ “ Last takeaway ──────────────────────────────────────── ✓ ─┐
  │  Batch review comments before replying.          ← bodyFont          │
  │  Refactor parser · Yesterday                     ← caption tertiary, │
  └──────────────────────────────────────────────────  link to session ──┘

  [StatTile Today 2h 15m · of 4h goal]  [StatTile Sessions 3]  ProportionBar(today, total: goal)

  TODAY'S SESSIONS ───────────────────────────────────────────────────────
   09:02  Code review sweep            ◉ Deep work     1h 12m   ›
   11:30  Standup                      ◉ Meetings        18m    ›
```
- Focus field: `insetField`, placeholder "Focus (optional)". Return in the field = Start.
- Start: `PrimaryButtonStyle`, `.controlSize(.large)`, `.keyboardShortcut(.defaultAction)`, label
  `Label("Start session", systemImage: "play.fill")`.
- Today's sessions: plain rows (no cards), hover highlight `textPrimary.opacity(0.05)`, click →
  `router.showSession`. Times `captionFont` tabular; duration `timerCompactFont`.
- No sessions today: a single `textTertiary` line "Nothing logged yet today." (not a full EmptyStateView).
- **Takeaway (`LiveTakeawayView`)**: the meta line ("Refactor parser · Yesterday") is a plain button that
  opens the source session in History. A trailing **Done** control (`checkmark`, `IconButtonStyle`, 24; 20 in
  compact places, `textTertiary`, help "Done: stop showing this takeaway") calls `engine.dismissTakeaway()`,
  which clears the source session's "Show in overlay & menu bar" — so it disappears everywhere (Today, menu
  bar, overlay), not just in this view. The same control appears in the menu bar panel and the overlay.
  Lifetime: by default a takeaway shows during the **next session only** (Settings ▸ General ▸ "Show takeaway
  for the next session only"); off = until a newer takeaway replaces it.

### 10.3 Today — active (A)

```
  [InlineBanner warning: Paused automatically when your Mac went to sleep.  (Resume) ✕]
  [InlineBanner warning: Still working? This session has run for 10 hours.
                          (Stop at last activity) (Stop now) (Keep going)]

  ◉ Deep work (large)                                   Started 09:02 · 3 segments
  Refactor parser ✎                                    ← titleFont, click to edit focus
  ⌨ Running on another Mac                             ← only when controlled elsewhere (caption, tertiary)

                        1:12:40                         ← TimerText(.hero), centered
                        ● Running   ·   this segment 0:24:10   ← LiveDot + caption + TimerText(.medium)

            ( ⏸ Pause )   ( ✂ Split )   [ ■ Stop ]           ⊡ trash (Discard)

  ProportionBar: ███████████▌████████▌██████░░░░░   ← segments, label colors
  09:02 Deep work · 10:15 Review · 10:48 Deep work   ← caption, tertiary

  NOTES ──────────────────────────────────────────────── ⊡ photo.badge.plus
  ┌ scroll box (max 320 pt, grows with content) ────────────────────────┐
  │ 10:15  Switching to review for Maya's PR.          ← oldest first    │
  │ 10:42  Found the off-by-one in the tokenizer.      ← newest at bottom│
  └─────────────────────────────────────────────────────────────────────┘
  [ Add a note…                                               ⏎ ]   ← insetField, focus via router
```
- Paused: hero digits use `timerPaused` (TimerText does), LiveDot shows the pause glyph, the caption
  reads "Paused" (never color only), and Pause becomes `( ▶ Resume )`.
- Stop is the only `PrimaryButtonStyle` while active. Discard is an icon button (trash) → confirm
  "Discard this session? Its notes and time will be deleted." `{!Discard}` / Cancel when
  `settings.confirmBeforeDiscard`.
- Label/focus/tags of the *current segment*: clicking the badge or focus opens a popover (LabelPicker,
  TagPicker, focus field, Save) → `engine.updateCurrentSegment`.
- Split popover (also opened by `router.splitRequest`, ⌘⇧D):
```
  ┌ Split segment ───────────────────────┐
  │ New focus  [__________________]      │
  │ Label ▾ ◉ Deep work                  │
  │ Tags  #coding (+ Add tag)            │
  │                 ( Cancel ) [ Split ] │
  └──────────────────────────────────────┘   width 300, padding spacingL, elevatedSurface
```
- Note composer: Return adds, field clears and keeps focus; Shift-Return is not needed (single line,
  `axis: .vertical` with `lineLimit(1...4)` is fine).
- **Live notes are oldest first** (a log that reads top to bottom, like a chat transcript), in a bounded
  scroll box (max 320 pt; shorter while there are few notes) directly above the composer. The box opens
  scrolled to the bottom (`defaultScrollAnchor(.bottom)`) and **auto-scrolls** to a newly added note
  (200 ms ease-out; no animation with Reduce Motion). Context menu per note: Copy, Edit (inline: Return
  saves, Esc cancels), Delete.
- **"Running on another Mac"**: when the active session was started or last changed on another Mac
  (synced via iCloud; `engine.isActiveSessionOnAnotherMac`), a quiet `Label("Running on another Mac",
  systemImage: "laptopcomputer")` in `captionFont` / `textTertiary` sits under the title (also in the menu
  bar panel and the regular overlay). Help: "This session was started or last changed on another Mac.
  Pausing, splitting or stopping it here takes it over." No color, no banner — it is information, not a
  warning. Controls stay enabled; using one takes the session over. If both Macs edited it, RootView shows
  `engine.handoffNotice` once as an info `InlineBanner`.

### 10.4 End-of-session sheet (A: `EndSessionSheet`) — min width 520

Built to be finished in about ten seconds: the essentials up front, everything else one click away.
```
  ┌───────────────────────────────────────────────────────────────┐
  │  Session complete                                 ← titleFont │
  │  1h 12m active · 6m paused · 3 segments · 4 notes ← callout    │
  │  [Short session — discard it?]  (warning banner if < 60 s)     │
  │                                                               │
  │  Title     [ Refactor parser___________________________ ]     │
  │  Label     ▾ ◉ Deep work                                      │
  │  Tags      #coding #review (+ Add tag)                        │
  │  Takeaway  [ Batch review comments…______________ ] 42/140    │
  │            ☑ Show in overlay & menu bar                        │
  │                                                               │
  │  ███████████▌████████▌██████   ▸ 3 segments   ← ProportionBar  │
  │  ▸ 4 notes                                     ← disclosures   │
  │  ▸ Add learning points  (LearningsEditor .compact, B)          │
  │                                                               │
  │  {!Discard}            ( Resume session )   [ Save  ⌘↩ ]      │
  └───────────────────────────────────────────────────────────────┘
```
- Discard is two-phase: the sheet closes first (`engine.discardPendingSession()`), and RootView's sheet
  `onDismiss` deletes the session (`engine.finishPendingDiscard()`), so nothing on screen reads a deleted model.
- Use `Form { … }.formStyle(.grouped)` *or* a plain VStack with leading labels column (width 64,
  `calloutFont`, `textSecondary`). Sheet background: system (do not override).
- Title field takes focus on appear; placeholder "Untitled session".
- Esc = Save as-is (`.onExitCommand` / `.keyboardShortcut(.cancelAction)` on a hidden Save path).

### 10.5 Menu bar (A: `MenuBarLabelView`, `MenuBarPanelView`) — width 320

```
  ┌────────────────────────────────────────┐   themedPanelBackground() (no radius)
  │ ● Running                 ◉ Deep work  │   caption + LabelBadge(.small)
  │ 1:12:40                                │   TimerText(.large)
  │ Refactor parser · segment 0:24:10      │   callout secondary
  │ ( ⏸ Pause ) ( ✂ Split ) [ ■ Stop ]      │   controlSize(.small)
  │ [ Quick note…                     ⏎ ]  │   insetField
  │────────────────────────────────────────│
  │ “ Batch review comments before replying│   takeaway (if setting on), 3 lines max
  │ Today 2h 15m of 4h  ▓▓▓▓▓▓░░░░          │   ProportionBar(total: goal)
  │────────────────────────────────────────│
  │ ☐ Show overlay                    ⌘⇧O  │   Toggle(.checkbox) or menu-like row
  │ Open Worklog                           │   menu-like rows: full-width, hover fill
  │ Settings…                          ⌘,  │
  │ Quit Worklog                       ⌘Q  │
  └────────────────────────────────────────┘
```
- Idle: status line "Not tracking", LabelPicker (`.labelsHidden()`) + `[ ▶ Start · Deep work ]` (the
  Start button names the label it will use). "Show overlay" while idle with "hide when idle" on adds the
  hint "Appears when a session starts".
- Takeaway row has the same Done control (`checkmark`, 20) as Today; "Running on another Mac" hint under
  the timer when it applies.
- Bottom rows are menu-like: `Button` with a private full-width row style (hover
  `textPrimary.opacity(0.06)`, radiusS), keyboard hints in `monoFont` `textTertiary`.
- Padding `spacingL`; sections separated by 1 pt `separator` rules with `spacingM` around them.
- With `theme.usesMaterials` the system already gives the window vibrancy; `themedPanelBackground()` keeps
  it consistent for Graphite (solid).

### 10.6 Floating overlay (A: `OverlayView`) — width 300 (220 compact)

```
  Regular (300)                              Compact (220)
  ╭──────────────────────────────────╮       ╭─────────────────────────╮
  │ ● ◉ Deep work                  ✕ │       │ ● 1:12:40   ⏸  ■      ✕ │
  │ 1:12:40                          │       │ Refactor parser         │
  │ Refactor parser · seg 0:24:10    │       ╰─────────────────────────╯
  │ ⊡⏸  ⊡✂  ⊡■            Today 2h15 │
  │ [ Note…                     ⏎ ]  │
  │ “ Batch review comments…         │
  ╰──────────────────────────────────╯
```
- Background: `themedPanelBackground(cornerRadius: theme.radiusL)`; padding `spacingM` (compact `spacingS`).
- Timer: `TimerText(.large)` regular, `.compact` in compact mode. Controls: `IconButtonStyle(size: 26)`
  (22 compact) with labels + help. Close `xmark` top-trailing, `IconButtonStyle(size: 18)`, `textTertiary`.
- Every section obeys its `overlayShow…` setting. Idle: takeaway (with Done ✓) + `[ ▶ Start · Deep work ]`
  (small). "Running on another Mac" hint in the regular layout only.
- Whole panel is draggable (window background); don't put drag-sensitive gestures on it.

### 10.7 History (B: `HistoryView`)

```
┌───────────────────────────────┬──────────────────────────────────────────────┐
│ [⌕ Search sessions      ]  ↕▾│                                              │
│ ◉ All  ◉ Deep work  ◉ Meetings│          SessionDetailView (10.8)            │
│───────────────────────────────│                                              │
│ ● Live session · 1:12:40   ›  │                                              │
│ TODAY                         │                                              │
│ Code review sweep      1h 12m │                                              │
│ ◉ Deep work  #review          │                                              │
│ ███▌██████                    │                                              │
│ …“found the off-by-one…”      │  ← search snippet, caption, match in accent  │
│ YESTERDAY                     │                                              │
│ Standup                  18m  │                                              │
└───────────────────────────────┴──────────────────────────────────────────────┘
   list min 300 / ideal 340                     detail min 480
```
- Day group headers: `relativeDayTitle`, `captionFont` semibold `textTertiary` (uppercase in Graphite via
  `theme.sectionHeaderUppercased`). Keep them sticky (`Section` in `List`).
- Row: title `headlineFont` (1 line) + duration `timerCompactFont` trailing; second line `LabelBadge(.small)`
  + up to 3 `TagChip`s + "+2"; optional `ProportionBar(height: 3)` of segments; search snippet
  `captionFont` `textSecondary`, 2 lines.
- Sort menu (`IconButtonStyle`, `arrow.up.arrow.down`) with checkmarked options: Newest first, Oldest
  first, Longest, Shortest, Label A–Z. Label filter chips: `TagChip(name:colorHex:isSelected:)` in a
  horizontal `ScrollView`.
- Selection uses the native List highlight (tinted by accent). ⌫ deletes with confirm. ⌘F focuses search.

### 10.8 Session detail (B: `SessionDetailView`)

```
  Refactor parser ✎                                         ⊡ ⋯ (Delete…)
  Wed, Oct 7 · 09:02 – 10:20 ✎ · 1h 12m active · 6m paused        ← callout secondary
  ◉ Deep work ▾   #coding #review (+ Add tag)

  SEGMENTS ──────────────────────────────────────────────── ⊡ ✂  (Timeline | List)
  Timeline: ProportionBar(height 10) with hover tooltips; below it, a row per segment:
   ◉ Deep work   Refactor parser     09:02–10:15   58m   ⋯ (Edit, Split at…, Merge with next,
   ◉ Review      Maya's PR           10:15–10:48   28m      Move boundary…, Delete)
   Boundary handle between rows: "⇆ 10:15" (QuietButton, small) → popover with DatePicker

  NOTES ──────────────────────────────────────────────────── ⊡ square.and.pencil
   NoteRow(note:, showsSegment: true)  … context menu: Edit, Change time…, Delete

  IMAGES ────────────────────────────────────────────────── ⊡ photo.badge.plus
   ┌────┐ ┌────┐ ┌────┐   adaptive grid min 120, radiusM thumbnails (thumbnailData only),
   └────┘ └────┘ └────┘   caption below in captionFont; drop target highlight = accent dashed border

  LEARNINGS ─────────────────────────────────────────────────
   LearningsEditor(session:, style: .full)
```
- Title edits inline (plain TextField in `titleFont`, `insetField` only while focused).
- Time editing: popover with two `DatePicker`s (`.stepperField`), Save/Cancel, errors shown inline in
  `danger` `captionFont`.
- Split sheet: `DatePicker` clamped within the segment, LabelPicker, TagPicker, focus; min width 420.
- **LearningsEditor (`.full`)**: "What I learned" `TextEditor` (min height 100, `insetSurface`,
  radiusS, `bodyFont`); "Takeaway for next time" single-line field + counter `n/140` (`captionFont`,
  `textTertiary`, `warning` past 140) + `Toggle("Show in overlay & menu bar")`; learning points as rows:
  drag handle (`line.3.horizontal`, tertiary), text field, `TagPicker`, mastery control (five 8 pt
  circles, filled up to rating in `accent`, click same value to clear), delete `IconButtonStyle(22)`.
  "+ Add learning point" `QuietButtonStyle` small. `.compact` hides learning-point tags/mastery behind a
  disclosure and caps the editor at 3 points visible.
- Detail column `maxWidth 760`, sections separated by `spacingXL`.

### 10.9 Learning (C: `LearningView`)

```
┌──────────────────────┬───────────────────────────────────────────────────────┐
│ [⌕ Search learnings] │  #coding                                   34 points  │ ← titleFont
│ All             128  │  ┌ Card ─ Points per week ───────────────────────────┐ │
│ Untagged         12  │  │ ▂▃▅▂▇▅▃  BarMark (accent) + LineMark mastery      │ │
│ #coding          34  │  │          (textSecondary, dashed; right axis 1–5)  │ │
│ #writing         20  │  └──────────────────────────────────────────────────┘ │
│ #review          18  │  OCTOBER 2026 ──────────────────────────────────────── │
│                      │   Oct 7  Prefer table-driven tests for the tokenizer.  │
│                      │          ●●●○○  · Refactor parser ›                    │
│                      │          “Session context: …learningText, 2 lines…”    │
└──────────────────────┴───────────────────────────────────────────────────────┘
```
- Tag list: native `List` with counts trailing (`captionFont`, `textTertiary`, tabular).
- Timeline: month headers via `SectionHeader`; point text `bodyFont`; meta line `captionFont`
  `textTertiary`; session title link in `accent` → `router.showSession`. Context quote `calloutFont`
  `textSecondary` with a 2 pt `separator` leading bar.

### 10.10 Stats (C: `StatsView`)

```
  Stats                                          [ 7D | 30D | 90D | 1Y | All ]  ← segmented Picker
  [Total 23h 40m] [Sessions 18] [Avg length 1h 19m] [Longest 3h 05m] [Streak 5 days]   StatTiles
  ┌ Card ─ Time by label ───────────────────────────────────────────────────────┐
  │ stacked BarMark by day/week, label colors; RuleMark goal (dashed)           │
  └─────────────────────────────────────────────────────────────────────────────┘
  ┌ Card ─ Label share ───────────────┐ ┌ Card ─ Top tags ────────────────────┐
  │ SectorMark donut (innerRadius 0.6)│ │ by time | by count (segmented)       │
  │ legend: dot + name + 3h 10m       │ │ horizontal BarMarks, chartPalette    │
  └───────────────────────────────────┘ └──────────────────────────────────────┘
  ┌ Card ─ When you work ──────────────────────────────────────────────────────┐
  │ RectangleMark heatmap weekday × hour, accent opacity ramp 0.08 → 1.0        │
  └─────────────────────────────────────────────────────────────────────────────┘
```
Chart styling (C):
- Series colors: label series use `label.color` (`.chartForegroundStyleScale(domain:range:)` built from
  labels); everything else `theme.chartColor(i)`. Unlabeled = `theme.textTertiary`.
- Axes: `AxisGridLine` `theme.separator` 0.5 pt; axis labels `captionFont` `textTertiary`; no axis lines.
- Bars: `.cornerRadius(theme.radiusS / 2)`; bar width ratio ~0.6. Goal: `RuleMark(y:)` dashed `[4, 3]`,
  `textSecondary`, annotation "Goal 4h" in `captionFont`.
- Durations on axes in hours (`formattedHoursDecimal`); tooltips/selection via `chartOverlay` optional.
- Chart height 220 (main), 180 (secondary). Not enough data → `EmptyStateView` in the pane (§12).

### 10.11 Settings (C: `SettingsView`) — 680 × 520, TabView

Use native `Form { }.formStyle(.grouped)` in every tab, `themedBackground()` on the tab content.
```
  [General] [Appearance] [Overlay] [Labels & Tags] [Account] [Data]

  Appearance
  ┌ Theme ────────────────────────────────────────────────────────────┐
  │ [Graphite swatch ✓]   [Paper swatch]   [Meadow swatch]            │ ← ThemePreviewSwatch in HStack
  └───────────────────────────────────────────────────────────────────┘
  Appearance      [ System | Light | Dark ]                    ← segmented, with systemImage
  Accent          ● ● ● ● ● ● ● ● ●   Theme Default             ← 16 pt circles, ring on selected;
                                                                  first = theme accent with "A" mark
  Text size       [ Small | Standard | Large | Extra Large ]    ← ThemeManager.textSize (extra)
                  (Reset Appearance)
```
- Labels & Tags: two-column: label list (drag to reorder, `ColorDot` + symbol + name + usage count) /
  editor (name field, `LabelColorPicker`, `SymbolPicker` in a 240 pt area, Archive / Delete…). Tags below:
  `Table` or List with name, parent label `LabelPicker(includeNone:true, title:"Parent")`, color, usage, ⋯.
- Delete label: sheet "Delete “Meetings”? 42 sessions use it. Move them to: ▾ [Unlabeled]" `{!Delete}`.
- Data: grouped sections Export / Import / Backups (list rows: date `shortDateTime`, reason, size in
  `monoFont`) / Danger zone (`DestructiveButtonStyle`, double confirm).
- **Data ▸ Recovery** (only while the store couldn't be opened, i.e. in-memory mode): a first section with an
  error `InlineBanner` "Worklog couldn’t open its data store, so nothing you change now is saved." and the
  action **Recover…**, plus a footnote. Recover… opens a sheet (`SettingsRecoverySheet`, width 540):
  "After relaunching" picker — restore a backup (from the list or a file) or start fresh (re-downloads from
  iCloud when sync is on); a consequence line ("Worklog moves the damaged store into the Recovered folder,
  quits, opens again and …"); reveal buttons (Damaged Data Store / Recovered Folder / Backups Folder); then
  ( Cancel ) [ **Move Aside and Relaunch…** ] → confirmation dialog. Nothing is ever deleted. After the
  relaunch RootView shows `persistence.launchNotice` once as an info banner (dismissable).
- Account: status row with `person.crop.circle` + name/“Guest”; `SignInWithAppleButton` styled
  `.signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)`, height 32, width 220.
- **Account ▸ iCloud sync status line** (from `SyncMonitor`), under the sync toggle: a small
  `ProgressView` while syncing, else `checkmark.icloud` (`textSecondary`) or `exclamationmark.icloud`
  (`warning`) after an error, + one `calloutFont` `textSecondary` line, refreshed every 30 s: "Syncing…" ·
  "Downloading your data from iCloud…" (first import) · "Last synced 5 minutes ago" · "Up to date" ·
  "Waiting for the first sync with iCloud…". The iCloud account state ("This Mac isn’t signed in to
  iCloud …") is its own row; a sync error is a warning `InlineBanner`. The "applies next time Worklog
  opens" note matters only when the toggle differs from what this launch used.

### 10.12 Welcome (C: `WelcomeView`)

```
                         Worklog                     ← largeTitleFont (serif in Paper)
          Track focused work, split it as your attention moves,
          and keep what you learned.                 ← bodyFont, textSecondary, centered, max 420

                   [  Sign in with Apple  ]           ← SignInWithAppleButton 260×36
                   ( Continue without signing in )   ← QuietButtonStyle

     Your data syncs with iCloud on this Mac's Apple Account either way.   ← captionFont tertiary
                                                       (only when CloudKit is in use; see below)
     [InlineBanner error …]                            (if auth.lastError)

                        Pick a look                  ← sectionHeaderFont, textSecondary
         [Graphite ✓]     [Paper]     [Meadow]       ← ThemeSwatchRow() (compact swatches, 124 pt)
          You can change it any time in Settings ▸ Appearance.   ← captionFont tertiary
```
Full-window `themedBackground()`, content vertically centered, no illustration, no gradients.
- The storage line is truthful: it mentions iCloud sync only when this launch actually uses CloudKit;
  otherwise "Your data is saved on this Mac." (+ where to turn sync on, or why iCloud isn't available).
- Theme picker: `ThemeSwatchRow()` — compact swatches show the theme in the current appearance with the
  name below; the summary is the tooltip. Clicking applies the theme immediately (the Welcome screen
  re-themes live), so the choice is self-explanatory. Graphite is preselected.

---

## 11. Interaction details

- **Hover:** subtle fill (`textPrimary.opacity(0.05–0.07)`) on rows and icon buttons; buttons provided by
  the design system already react. No hover-only information (anything in a tooltip is also reachable).
- **Focus:** native focus rings for native controls; DS buttons draw an accent ring when focused; inset
  fields turn their border accent (`insetField(isFocused:)`). Use `@FocusState` for: Today note composer
  (router.noteFocusRequest), History search (⌘F), EndSessionSheet title, popover search fields.
- **Keyboard:** Return submits single-line fields; ⌘↩ = sheet default action; Esc cancels/closes
  (EndSessionSheet: Esc = Save as-is); ⌫ deletes selected History row (confirm); arrow keys move list
  selection; Space toggles focused checkbox/toggle. Every icon-only button has `.help` *and*
  `.accessibilityLabel`.
- **Context menus:** rows (History sessions, notes, segments, learning points, images) have a context menu
  that mirrors their ⋯ menu. Destructive items last, with `role: .destructive`.
- **Confirmations:** `confirmationDialog` for Discard / Delete / Replace import / Delete all (double).
  Titles state the consequence: "Delete this session? This can’t be undone."
- **Tooltips:** `.help` on truncated titles, timestamps ("Edited Oct 7, 10:42"), chart segments.
- **Drag & drop:** image drop zones highlight with an accent dashed border (`StrokeStyle(dash: [5, 4])`)
  and `accent.opacity(0.06)` fill while targeted.

## 12. Empty states and copy

Voice: plain, short, sentence case, no exclamation marks, no emoji. Name the next step.

| Where | `EmptyStateView` title / systemImage / message / action |
|---|---|
| History, no sessions | "No sessions yet" / `clock` / "Sessions you finish appear here, grouped by day." / "Start a session" → `router.show(.today)` |
| History, no results | "No matches" / `magnifyingglass` / "Nothing matches “\(query)”. Try fewer words or a tag name." / — |
| History, nothing selected | "Select a session" / `sidebar.left` / "Choose a session to see its notes, segments and learnings." / — |
| Learning, no learnings | "Nothing learned… yet" / `lightbulb` / "Add learning points when you finish a session. They collect here by tag." / — |
| Learning, no tags | "No tags on your learnings" / `number` / "Tag learning points to follow how a topic develops." / — |
| Learning, no search results | "No matches" / `magnifyingglass` / "No learning points match “\(query)”." / — |
| Stats, not enough data | "Not enough data" / `chart.bar.xaxis` / "Finish a session in this range to see stats." / — |
| Labels, none | "No labels" / `tag` / "Labels sort your time into kinds of work." / "Restore defaults" |
| Session detail, no notes | inline `textTertiary`: "No notes." |
| Session detail, no images | inline: "Drop images here, paste, or use ＋." |
| Today, nothing logged | inline: "Nothing logged yet today." |
| Overlay / menu, no takeaway | omit the section entirely |

Banner copy (InlineBanner):
- local only (info): "Saving to this Mac only — \(reason)." dismissible.
- in-memory (error): "Your data couldn’t be opened. Changes in this session won’t be saved." action "Restore from backup…".
- auto-pause sleep (warning): "Paused when your Mac went to sleep." action "Resume".
- auto-pause quit (warning): "Paused when Worklog quit." action "Resume".
- long session (warning): "Still working? This session has been running for \(n) hours." actions per §7.3.
- short session in end sheet (warning): "This session was under a minute." action "Discard".

## 13. Accessibility

- **Contrast:** `textPrimary` and `textSecondary` meet ≥ 4.5:1 on `background`/`surface` in every theme and
  scheme; `textTertiary` (≥ 3:1 on background/surface) is for non-essential metadata only. `onAccent` meets ≥ 4.5:1 on the theme
  default accents; accent overrides pick dark/white text by contrast.
- **Color is never the only signal:** badges show names; paused shows "Paused"/pause glyph; selected chips
  have a border; the selected swatch has a ring and the `.isSelected` trait.
- **VoiceOver:** TimerText → label "Elapsed time", value "1 hour, 12 minutes, 40 seconds[, paused]".
  LiveDot → "Running"/"Paused". LabelBadge → "Label: Deep work". TagChip → "Tag: coding" (+ "Remove tag
  coding" button). SectionHeader has the header trait. Charts: add `.accessibilityLabel` per mark
  ("Monday, Deep work, 2 hours") and a summary label on the chart.
- **Text size:** Settings → Appearance → Text size scales every theme font (0.92–1.25). Layouts must not
  clip at Extra Large: use `fixedSize(horizontal: false, vertical: true)` for wrapping text, avoid fixed
  heights on text containers (the overlay/menu panel have fixed *widths* only).
- **Keyboard:** everything reachable without a mouse (see §11). Custom buttons are real `Button`s.
- **Reduce Motion / Transparency:** honor `accessibilityReduceMotion` (DS components already do).
  `themedPanelBackground` switches from the material to solid `elevatedSurface` when Reduce Transparency
  is on; if you fill a panel yourself, check `@Environment(\.accessibilityReduceTransparency)` too.

## 14. Do / Don't (quick checklist for feature code)

- Do read `@Environment(\.theme)`; don't use `Color.blue`, `.font(.title)`, magic paddings or radii.
- Do use `label.color` / `tag.color`; don't invent label colors.
- Do wrap running timers in `TimelineView(.periodic(from: .now, by: 1))`; don't use `engine.tick` (menu bar label only).
- Do use one `PrimaryButtonStyle` per region; don't make destructive buttons filled.
- Do use native `Form`, `Picker`, `Toggle`, `DatePicker`, `List`; don't re-skin them.
- Do give icon-only buttons `.help` + `.accessibilityLabel`.
- Don't add shadows, gradients, emoji or decorative illustrations.

## 15. Adding a theme

1. Add a case to `ThemeID` (e.g. `case slate`) with `displayName`, `summary`, `systemImage`.
2. Create `Worklog/DesignSystem/Themes/SlateTheme.swift`:
   ```swift
   extension Theme {
       static func slate(_ scheme: ColorScheme) -> Theme {
           var t = Theme(id: .slate, colorScheme: scheme)   // neutral system defaults
           let dark = scheme == .dark
           t.background = Color(hex: dark ? "#…" : "#…")
           // …every color token, chartPalette (≥ 8), panelMaterial/usesMaterials,
           // radii, borderWidth, shadow*, chipRadius, tintOpacity,
           // sectionHeaderUppercased/Ruled, timerUsesAccent…
           t.fontRecipe = ThemeFontRecipe(displayDesign: .serif, /* … */ timerHeroSize: 64, timerSize: 32)
           t.applyFonts(scale: 1)                           // builds every font from the recipe
           return t
       }
   }
   ```
3. Add `case .slate: theme = Theme.slate(colorScheme)` to the switch in `Theme.make`.
4. Check: both schemes, all accents, text size Extra Large, contrast of text tokens (§13), the swatch in
   Settings (it renders automatically). No feature code changes are needed.

Theme ids persist by raw value (`"appearance.themeID"`); never rename or remove a case — unknown values
fall back to `ThemeID.default` (`.graphite`).
