# Worklog — Design (docs/DESIGN.md)

> Owner: **DES**. This is the design language and the screen-by-screen UX spec for feature programmers
> **A** (live session, end-session sheet, menu bar, overlay), **B** (history, session detail, learnings
> editor) and **C** (learning, stats, settings, welcome). The API contract is `docs/ARCHITECTURE.md` §4;
> this document says **how to use it**. Where the two disagree on a signature, ARCHITECTURE.md wins.
>
> **Round 2** is folded in: Settings lives in the main window (§10.1, §10.11), app shortcuts are customizable
> (§11.1), the overlay has an editable layout (§10.6), and all copy follows the guideline in §12.0.

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

Selected in Settings ▸ Appearance (`ThemeManager.themeID`) or on the Welcome screen (`ThemeSwatchRow`),
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
| Shortcuts | `keyboard` | Reset to default | `arrow.counterclockwise` |
| Remove (edit mode) | `minus` on a `danger` badge | Add (edit mode) | `plus` on an accent badge |
| Settings (active) | `gearshape.fill` (accent) | Live session in History | `timer` |

Menu bar label (A): `timer` idle, `record.circle` running, `pause.circle` paused (contract §5.3).

### 6.1 App icon (`Worklog/Resources/Assets.xcassets/AppIcon.appiconset`)

A **green clothbound notebook** (user-supplied): a flat sage-green cover with a darker spine line, a cream page
block along the bottom edge and a vertical red-orange elastic band on the right, centred on a deep forest-green
ground. Flat shapes, no gradient or texture, so it stays legible at 16 px. It reads as "a log book", the app's
name. The ten mac slots (16–512 @1x/@2x) are the supplied PNGs; to change the icon, replace all ten together,
never a single size by hand.

---

## 7. Motion

- Default: **none or very short**. Hover fades 120 ms ease-out; press 80 ms. Sheets/popovers: system.
- Allowed: `LiveDot` breathing (1.6 s ease-in-out, opacity 1 → 0.45), cross-fade when switching
  idle ⇄ active on Today (`.transition(.opacity)`, 200 ms), expanding a note (no animation needed).
- **Edit-mode wiggle** (`View.wiggle(_:seed:)`, Settings ▸ Overlay layout editor) is the *only* looping
  motion besides `LiveDot`: ±1.2° rotation, 0.28 s period, a per-item phase (`seed`), only while editing.
  It is driven by `TimelineView(.animation(paused:))`, never by a `repeatForever` animation (those leak into
  unrelated transitions). Under Reduce Motion there is no rotation: a 1 pt dashed accent outline (`radiusS`)
  marks the editable items instead. Removing/reordering items animates 150 ms ease-out (`nil` under
  Reduce Motion).
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
| `TagChip(tag:isSelected:onRemove:)` | Single tag. Dot appears only for tags with a non-default color. Remove (×) help "Remove", a11y "Remove tag *name*". Not a filter: use `FilterChip`. |
| `ColorDot(hex:size:)` | Decorative dot; pair with text. |
| `TimerText(_:style:isPaused:)` | Pure display. Wrap in `TimelineView(.periodic(from: .now, by: 1))` when running; render statically when paused. |
| `PrimaryButtonStyle` | The one primary action (Start, Save, Create). Add `.keyboardShortcut(.defaultAction)` where it's the default. |
| `QuietButtonStyle` | Secondary actions (Pause, Split, Cancel, Attach, Restore…). |
| `DestructiveButtonStyle` | Discard / Delete. Always followed by a confirmation (`confirmationDialog`). |
| `IconButtonStyle(size:)` | Icon-only (toolbar-like) buttons; 28 default, 22 in dense rows, 20 in banners. Always `.accessibilityLabel` + `.help`. |
| `EmptyStateView(…)` | Whole-pane empty states (copy in §12). |
| `SearchField(text:prompt:)` | History, Learning, popovers. To focus it from a shortcut (Find in History) use the extra `init(text:prompt:isFocused:)`. Help on the field: "Search". |
| `StatTile(…)` | Stats and Today totals, in an adaptive grid (min 150). |
| `FlowLayout(spacing:lineSpacing:)` | Wrapping chips and swatches. |
| `InlineBanner(…)` | Top-of-pane notices (storage mode, auto-pause, long session, errors). Max two stacked. |
| `ThemePreviewSwatch(themeID:isSelected:compact:)` | Appearance tab (`compact: false`, default: light + dark halves, name + summary, 196 pt); Welcome (`compact: true`: one preview in the current appearance, name only, 124 pt; no tooltip, VoiceOver reads the summary as the value). Wrap in a `.plain` Button — or use `ThemeSwatchRow`. |
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

### 8.1 Round 2 components

All use theme tokens only, honour Reduce Motion (hover fades and selection changes are `nil`-animated) and
need no Reduce Transparency handling (no materials). Signatures are final (ARCHITECTURE §11).

| Component | Signature | Look and behaviour |
|---|---|---|
| `FilterChip` | `FilterChip(_ title: String, colorHex: String?, isSelected: Bool, action: () -> Void)` | The chip *is* the button. At Standard text size: `calloutFont` medium, padding 11 × 5, min height 26 (× `textScale`), `chipShape`, 8 pt `ColorDot` when `colorHex != nil`. Selected: accent tint fill + 1 pt accent stroke + accent text. Unselected: `insetSurface` + `separator` stroke + `textPrimary`. Hover `textPrimary.opacity(0.05)`. a11y label = title + `.isSelected`. The caller adds `.help(title)`. Use in a horizontal `ScrollView(showsIndicators: false)` with `HStack(spacing: 6)`. |
| `PillTabBar` | `PillTabBar(items: [Item], selection: Binding<Item>, title: (Item) -> String, systemImage: (Item) -> String?)` (`Item: Hashable & Identifiable`) | Settings section switcher. Icon + title, `calloutFont` medium, padding 10 × 5, `radiusS`. Selected: accent tint fill + accent text; unselected `textSecondary`, hover fill `textPrimary.opacity(0.06)`. Natural width when it fits; when it doesn't (`ViewThatFits`), unselected pills drop to icon-only with the title as tooltip, then every pill is icon-only, and only then does the row scroll horizontally. Buttons keep their title as a11y label and carry `.isSelected`; the container is "Sections". |
| `ValueSentence` | `ValueSentence(_ prefix: String, value: String, suffix: String = "")` | "Keep the latest **10 backups**": one concatenated `Text`; the value is bold + `accent`, prefix/suffix `textPrimary`, all in the inherited font, so it shares the baseline and wraps like a sentence. |
| `ValueStepper` | `ValueStepper(_:value:in:step:suffix:format:)` for `Binding<Double>` and `Binding<Int>` | `ValueSentence` … native `Stepper` (labels hidden) trailing, row centred vertically. a11y: one adjustable element, label = prefix + suffix, value = the formatted value. |
| `ValueSlider` | `ValueSlider(_:value:in:step:suffix:format:)` (`Binding<Double>`) | `ValueSentence` … native `Slider` (labels hidden, width 200) trailing. Same a11y as the stepper. |
| `ValuePicker` | `ValuePicker(_:selection:options:suffix:title:)` (`Option: Hashable`) | "Week starts on **Monday ⌄**": the bold accent value + a small chevron is a plain button that opens a popover list (checkmark on the selected option; click, Return or Space picks and closes; ↑/↓ move; Esc closes). First-text-baseline aligned with the prefix, same font. For short option lists inside sentences; lists over 12 options scroll in the popover (highlight kept visible). |
| `ShortcutRecorder` | `ShortcutRecorder(shortcut: StoredShortcut?, accessibilityName: String, onRecord: (StoredShortcut) -> Void, onClear: () -> Void)` | Key-cap field; see §11.1. It never validates: pass the result to `ShortcutStore.set(_:for:)` and show its message under the row. |
| `ResetToDefaultButton` | `ResetToDefaultButton(isDefault: Bool, accessibilityLabel: String, action: () -> Void)` | `arrow.counterclockwise` in `IconButtonStyle(size: 22)`, disabled at the default, help "Reset". |
| `RemoveBadgeButton` | `RemoveBadgeButton(accessibilityLabel: String, action: () -> Void)` | Edit-mode (−): 18 pt `danger` circle, white `minus` (9 pt bold), 1.5 pt `elevatedSurface` ring, 24 pt hit area, help "Remove". Place at the item's top-leading corner, offset (−6, −6). |
| `AddBadgeButton` | `AddBadgeButton(accessibilityLabel: String, action: () -> Void)` | Edit-mode (+): 28 pt accent circle, `onAccent` `plus` (12 pt bold), help "Add" (dropped while disabled so the caller's reason shows, e.g. "All elements shown"). |
| `View.wiggle(_:seed:)` | `func wiggle(_ isActive: Bool, seed: Int = 0) -> some View` | Edit-mode wiggle (§7). The view keeps its identity when edit mode toggles. |

## 9. Shared data-bound controls (`Worklog/Shared`)

| Control | Behavior |
|---|---|
| `LabelPicker(selection:includeNone:title:)` | Native pop-up `Picker` (`.menu`): "None", divider, non-archived labels by `sortIndex` with colored symbol; an archived current selection is listed as "Name (archived)". Shows its `title` on the left; use `.labelsHidden()` in compact places. |
| `LabelValuePicker(_:selection:)` | Settings value sentence over labels ("Default label **Work ⌄**", "Parent label **None ⌄**"): a `ValuePicker` with "None" + the same options as `LabelPicker` (archived current selection as "Name (archived)"); a deleted selection reads "None" and nil is written back. |
| `TagPicker(selection:scopeLabel:allowsCreate:)` | Selected tags as removable chips + a dashed "+ Add tag" chip that opens a popover: search field (focused), **scope label's tags**, **Global**, and while searching **Other labels**; rows toggle (multi-select, popover stays open); "Create “x”" creates a *global* tag via `TaxonomyOps.createTag(name:in:)` and selects it. Return = toggle exact/only match or create. Bind with `$session.tagList`, `$segment.tagList`, `$point.tagList`. The picker does not call `touch()`. |
| `TagChipsRow(tags:)` | Read-only chips; renders nothing when empty. |
| `NoteRow(note:showsSegment:)` | `10:42` (caption, tabular, tertiary) · selectable body text (6 lines + "Show more") · optional segment caption (dot + focus) · "Edited". Read-only; add `.contextMenu` (Edit / Change time / Delete) in your feature. |
| `LabelColorPicker(hex:)` | 15 swatches (wrapping) + system color well for custom; selected ring. |
| `SymbolPicker(symbolName:)` | Adaptive grid (30 pt cells) of `LabelPalette.symbols`; current custom symbol shown first. Put it in a popover or a fixed-height area (~240 pt). |

**Deleted models.** A label or tag can be deleted or merged in Settings while another view still holds it
(Today's start label in `@State`, the menu bar picker, an open editor). Reading such a model traps, so:
`LabelPicker` treats a deleted selection as nil, `TagPicker` drops deleted tags — both never read them,
never offer them, and write the cleaned value back to the binding (on appear and whenever the label/tag
list changes). `TagChipsRow`, `TagChip`, `LabelBadge` (→ "Unlabeled") and `NoteRow` (renders nothing for a
deleted note; skips a deleted segment/label) also guard. Feature code that reads a held model outside these
controls checks `ModelLiveness.isLive(_:)` first.

---

## 10. Screens

Wireframes are schematic (not to scale). `[ Primary ]` = PrimaryButtonStyle, `( Quiet )` = QuietButtonStyle,
`{!Danger}` = DestructiveButtonStyle, `⊡` = IconButtonStyle, `▾` = native pop-up/menu, `◉` = LabelBadge,
`#tag` = TagChip, `●` = LiveDot. Every pane: `themedBackground()` on the root, padding `spacingXL`,
content column `maxWidth ≈ 760` centered unless stated. A pane's minimum size must never depend on its data:
any flexible container that wraps data-dependent content declares `minWidth: 0` / `minHeight: 0`, and user
text truncates (`lineLimit(1)` + tail) instead of using a horizontal `.fixedSize()`.

### 10.1 Main window shell (CORE, for reference)

```
┌──────────────┬──────────────────────────────────────────────────────────────┐
│ ◷ Today      │  [InlineBanner: iCloud sync failed; …    (Details…)   ✕]    │
│ ↺ History    │                                                              │
│ ✧ Learning   │            (detail pane — §10.2… or Settings §10.11)         │
│ ▥ Stats      │                                                              │
│              │                                                              │
│              │                                                              │
│ ● 1:12:40    │  ┐                                                           │
│   Deep work  │  │ pinned footer: .safeAreaInset(edge: .bottom) on the List, │
│──────────────│  │ filled with sidebarBackground                             │
│ ◯ Guest   ⚙  │  ┘                                                           │
└──────────────┴──────────────────────────────────────────────────────────────┘
```
- **Sidebar rows** are `SidebarItem.primaryItems` (Today, History, Learning, Stats) in a `.sidebar` List.
- **Footer (pinned):** mini status row (`LiveDot` + `TimerText(.compact)` + label name in `captionFont`
  `textSecondary`; help "Show session"), a hairline, then the account icon + name (one plain button → Settings ▸
  Account, help "Account") and the **Settings gear**. The footer is a `.safeAreaInset(edge: .bottom, spacing: 0)`
  of the List, not a VStack sibling, so nothing in the detail can push it off-screen.
- **Settings is a detail destination** (`SidebarItem.settings`), not a window. The gear is
  `IconButtonStyle(size: 24)`: `gearshape` in `textSecondary`, or `gearshape.fill` in `accent` with the
  `.isSelected` trait while Settings shows (then no List row is selected); help and a11y label "Settings".
  ⌘, , the app menu "Settings…", the menu bar "Settings…" and banner actions ("Details…", "Restore…") all
  open it (to the right section), reopening the main window if it was closed.
- **Size barrier:** the detail column is `frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight:
  .infinity).clipped()`, so a page's content can never raise the window's minimum size. The window keeps
  min 900 × 600 (`.windowResizability(.contentMinSize)`), default 1100 × 720.

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
- No sessions today: a single `textTertiary` line "Nothing logged today." (not a full EmptyStateView).
- **Takeaway (`LiveTakeawayView`)**: the meta line ("Refactor parser · Yesterday") is a plain button that
  opens the source session in History. A trailing **Done** control (`checkmark`, `IconButtonStyle`, 24; 20 in
  compact places, `textTertiary`, help "Done") calls `engine.dismissTakeaway()`,
  which clears the source session's "Show in overlay & menu bar" — so it disappears everywhere (Today, menu
  bar, overlay), not just in this view. The same control appears in the menu bar panel and the overlay.
  Lifetime: by default a takeaway shows during the **next session only** (Settings ▸ General ▸ "Show takeaway
  for the next session only"); off = until a newer takeaway replaces it.

### 10.3 Today — active (A)

```
  [InlineBanner warning: Paused while your Mac slept.                      (Resume) ✕]
  [InlineBanner warning: Running for 10 hours. Still working?
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
- Stop is the only `PrimaryButtonStyle` while active. Discard is an icon button (trash, help "Discard",
  a11y "Discard session") → confirm "Discard this session?" (message "Its notes and time will be deleted.")
  `{!Discard}` / Cancel when `settings.confirmBeforeDiscard`.
- Tooltips: "Pause" / "Resume", "Split segment", "Stop", "Discard". No shortcut glyphs in tooltips: the menus
  show the user's current shortcuts.
- Label/focus/tags of the *current segment*: clicking the badge or focus opens a popover (LabelPicker,
  TagPicker, focus field, Save) → `engine.updateCurrentSegment`.
- Split popover (also opened by `router.splitRequest`, i.e. the Split Segment shortcut):
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
  bar panel and the regular overlay). Help: "Running on another Mac" (pausing, splitting or stopping it
  here takes it over). No color, no banner — it is information, not a
  warning. Controls stay enabled; using one takes the session over. If both Macs edited it, RootView shows
  `engine.handoffNotice` once as an info `InlineBanner`.

### 10.4 End-of-session sheet (A: `EndSessionSheet`) — min width 520

Built to be finished in about ten seconds: the essentials up front, everything else one click away.
```
  ┌───────────────────────────────────────────────────────────────┐
  │  Session complete                                 ← titleFont │
  │  1h 12m active · 6m paused · 3 segments · 4 notes ← callout    │
  │  [Under a minute long.  (Discard)]  (warning banner if < 60 s) │
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
  │  {!trash}              ( Resume session )   [ Save ]          │
  └───────────────────────────────────────────────────────────────┘
```
- **Discard is icon-only**: `Label("Discard", systemImage: "trash").labelStyle(.iconOnly)` in
  `DestructiveButtonStyle`, help "Discard", a11y "Discard session", still confirmed ("Discard this session?").
- Save: `PrimaryButtonStyle`, help "Save", shortcut = `ShortcutStore` "Save Session Review" (default ⌘↩,
  shown in no label or tooltip). "Resume session" (Quiet) keeps tracking; the stopped time counts as a pause.
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
  │ ☐ Show overlay                    ⇧⌘O  │   hint = ShortcutStore.displayString(for: .toggleOverlay)
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
  `textPrimary.opacity(0.06)`, radiusS), keyboard hints in `monoFont` `textTertiary`. The overlay hint reads
  `ShortcutStore.displayString(for: .toggleOverlay)` and is hidden when unassigned; "⌘," and "⌘Q" are fixed
  and stay literal. This hint column is one of the three places shortcut glyphs may appear (§12.0).
- Padding `spacingL`; sections separated by 1 pt `separator` rules with `spacingM` around them.
- With `theme.usesMaterials` the system already gives the window vibrancy; `themedPanelBackground()` keeps
  it consistent for Graphite (solid).

### 10.6 Floating overlay (F2: `OverlayView`, `OverlayContent`) — width 300 (220 compact)

```
  Regular (300)                              Compact (220)
  ╭──────────────────────────────────╮       ╭─────────────────────────╮
  │ ● ◉ Deep work                  ✕ │       │ ● 1:12:40   ⏸  ■      ✕ │
  │ 1:12:40                          │       │ Refactor parser         │
  │ Refactor parser · seg 24:10      │       ╰─────────────────────────╯
  │ ⊡⏸  ⊡■  ⊡✂           Today 2h 15m │
  │ [ Note…                        ] │
  │ “ Batch review comments…         │
  ╰──────────────────────────────────╯
```
**Layout model.** The overlay shows an ordered list of elements, `AppSettings.overlayLayout: [OverlayElement]`
(persisted as raw values under `settings.overlayLayout`; the old `overlayShow…` toggles were migrated once).
Elements: Label, Timer, Segment focus, Controls, Split, Today’s total, Quick note, Takeaway. Default (fresh
install and "Reset Layout"): Label, Timer, Segment focus, Controls, Split, Quick note, Takeaway. An empty layout
is allowed: only the header shows.

**Rendering** (one renderer, `OverlayContent`, for the live overlay, the preview and the editor):
- Background: `themedPanelBackground(cornerRadius: theme.radiusL)`; padding `spacingM` (compact `spacingS`).
- **Header chrome** (always there, not an element, can't be removed): `LiveDot` (idle: `timer` glyph), then the
  leading run of inline elements if the layout starts with one, otherwise a status word ("Running" / "Paused" /
  "Not tracking"); close `xmark` top-trailing, `IconButtonStyle(size: 18)`, help "Hide overlay".
- **Inline elements** (Label, Controls, Split, Today’s total; Timer when compact) — consecutive ones share a
  wrapping row (`FlowLayout`); Today’s total is trailing when it ends a row. **Full-width elements:** Timer
  (`TimerText(.large)`), Segment focus ("focus · seg 24:10"), Quick note (`insetField`), Takeaway.
- Controls: pause/resume + stop, `IconButtonStyle(size: 26)` (22 compact), help "Pause"/"Resume", "Stop".
  Split: `scissors`, help "Split segment".
- Idle: Takeaway (with Done ✓), Today’s total and Controls (as "Review…" when a review is pending, plus
  `[ ▶ Start · Deep work ]`, help "Start session") render in layout order; the rest is hidden.
- "Running on another Mac" is chrome under the header, live only.
- Whole panel is draggable (window background); don't put drag-sensitive gestures on it.

#### 10.6.1 Layout editor (Settings ▸ Overlay ▸ Layout, F2: `OverlayLayoutEditor`)

Direct manipulation, in the spirit of iPhone Control Center: what you see is the overlay, at real size.
```
  ┌ Layout ───────────────────────────────────────────────────────────────┐
  │ [ Running | Idle ]                                           ( Edit ) │  ← header row
  │ ┌ stage: insetSurface, radiusM, padding spacingXL, min height 200 ──┐ │
  │ │            ╭────────────────────────────╮                          │ │
  │ │            │ ● ⊖◉ Deep work           ✕ │   ← live preview, current │ │
  │ │            │ ⊖1:12:40                   │     theme, compact and    │ │
  │ │            │ ⊖Refactor parser · seg …   │     opacity settings      │ │
  │ │            ╰────────────────────────────╯                          │ │
  │ │                         (+)                ← AddBadgeButton        │ │
  │ └────────────────────────────────────────────────────────────────────┘ │
  └───────────────────────────────────────────────────────────────────────┘
```
- **At rest:** a non-interactive preview (`allowsHitTesting(false)`, nothing touches the engine) with a
  segmented "Running / Idle" preview switch (small) and an "Edit" button (`QuietButtonStyle`).
- **Edit** → the preview always shows the running sample with every layout element; the header row shows
  "Reset Layout" (Quiet, disabled at the default) and "Done" (`PrimaryButtonStyle`) instead.
  - Each element **wiggles** (`.wiggle(true, seed: index)`; dashed outline under Reduce Motion) and gets a
    **(−)** `RemoveBadgeButton` at its top-leading corner (offset −6, −6; a11y "Remove *Element*").
  - **Drag to reorder**, live: neighbours make room as you drag (150 ms ease-out, none under Reduce Motion);
    the drag preview is not rotated. The header chrome doesn't wiggle and can't be removed or moved.
  - **(+)** `AddBadgeButton` (a11y "Add element") under the preview opens a popover listing the hidden
    elements (icon + title); clicking one appends it; the popover closes when none are left. With everything
    shown the button is disabled with help "All elements shown".
  - Keyboard / VoiceOver: each element has a context menu and accessibility actions "Move Up", "Move Down",
    "Remove".
- Every change writes `settings.overlayLayout` immediately; the real overlay updates live. "Done" only leaves
  edit mode (there is nothing to save or cancel).

### 10.7 History (F1: `HistoryView`)

```
┌───────────────────────────────┬┬─────────────────────────────────────────────┐
│ [⌕ Search               ]  ↕▾ ││                                             │
│ (All) (● Deep work) (● Meet…  ││          SessionDetailView (10.8)           │
│───────────────────────────────││                                             │
│ ● Live session · 1:12:40   ›  ││                                             │
│ TODAY                         ││                                             │
│ Code review sweep      1h 12m ││                                             │
│ ◉ Deep work  #review          ││                                             │
│ ███▌██████                    ││                                             │
│ …“found the off-by-one…”      ││  ← search snippet, caption, match in accent │
│ YESTERDAY                     ││                                             │
│ Standup                  18m  ││                                             │
└───────────────────────────────┴┴─────────────────────────────────────────────┘
   list 340 (280–460), drag the divider    detail: everything else, min 0
```
- **Columns:** a plain `HStack`, never `HSplitView` (it leaks its panes' minimum sizes into the window). The
  list has an explicit width, default 340, clamped to 280 … min(460, total − 420), persisted in
  `history.listWidth`. The divider is a 1 pt `separator` line with an invisible 7 pt drag handle (resize
  cursor on hover, double-click resets to 340, hidden from VoiceOver). The detail takes the rest with
  `minWidth: 0` and is clipped, so **switching sessions never changes either width**.
- Day group headers: `relativeDayTitle`, `captionFont` semibold `textTertiary` (uppercase in Graphite via
  `theme.sectionHeaderUppercased`). Keep them sticky (`Section` in `List`).
- Row: title `headlineFont` (1 line) + duration `timerCompactFont` trailing; second line `LabelBadge(.small)`
  + up to 3 `TagChip`s + "+2"; optional `ProportionBar(height: 3)` of segments; search snippet
  `captionFont` `textSecondary`, 2 lines.
- Sort menu (`IconButtonStyle`, `arrow.up.arrow.down`) with checkmarked options: Newest first, Oldest
  first, Longest, Shortest, Label A–Z.
- **Label filter:** `FilterChip`s ("All" without a dot, then one per label with its color dot), `.help(title)`,
  `HStack(spacing: 6)` in a horizontal `ScrollView(showsIndicators: false)`, vertical padding 2.
- Selection uses the native List highlight (tinted by accent). ⌫ deletes with confirm ("Delete this
  session?" / "This can’t be undone."). The Find in History shortcut (default ⌘F) focuses search; the
  search field's help is "Search".
- Empty states: §12.

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
  drag handle (`line.3.horizontal`, tertiary), text field, `TagPicker`, mastery control, delete
  `IconButtonStyle(22)`.
- **Mastery** is the user's own rating of how well they know a learning point: 1 = just met it, 5 = could
  teach it; 0 = not rated. It feeds the mastery line on the Learning page. The control is a "Mastery" caption
  (`captionFont`, `textTertiary`) followed by five 8 pt circles filled up to the rating in `accent`. Each
  dot's tooltip names its value, "Mastery 3 of 5"; the current one reads "Clear mastery" (clicking it clears
  the rating). VoiceOver: one adjustable element "Mastery". Read-only places show "Mastery 3/5".
  "+ Add learning point" `QuietButtonStyle` small. `.compact` hides learning-point tags/mastery behind a
  disclosure and caps the editor at 3 points visible.
- Detail column: `.frame(minWidth: 0, maxWidth: 760, alignment: .topLeading)`, then padding, then
  `.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)`: leading-aligned so it never re-centres
  between sessions. Sections separated by `spacingXL`. No horizontal `.fixedSize()` on user text (titles,
  labels, focus): truncate with `lineLimit(1)` + tail + `layoutPriority(1)` instead.

### 10.9 Learning (C: `LearningView`)

```
┌──────────────────────┬───────────────────────────────────────────────────────┐
│ [⌕ Search learnings] │  #coding                                   34 points  │ ← titleFont
│ All             128  │  ┌ Card ─ Points per week ───────────────────────────┐ │
│ Untagged         12  │  │ ▂▃▅▂▇▅▃  bars (accent) + LineMark mastery         │ │
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
  │ stacked bars by day/week/month, label colors; RuleMark goal (dashed)        │
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
- Bars: `.cornerRadius(theme.radiusS / 2)` (single-series bars); bar width ratio ~0.6. Goal: `RuleMark(y:)`
  dashed `[4, 3]`, `textSecondary`, annotation "Goal 4h" in `captionFont`.
- Date bars (time per day/week/month, learning points per week/month) are drawn as
  `RectangleMark(xStart:xEnd:yStart:yEnd:)` across each bucket (`bucketStart` → next bucket start, inset 20 % per
  side ≈ width ratio 0.6); stacked series carry their own offsets from `StatsCalculator`. No date-unit binning
  (`.value(_:_:unit:)`), so week buckets always honor Settings ▸ week start. X-axis ticks sit at bucket midpoints
  and are labeled with the bucket's start.
- Durations on axes in hours (`formattedHoursDecimal`); tooltips/selection via `chartOverlay` optional.
- Chart height 220 (main), 180 (secondary). Not enough data → `EmptyStateView` in the pane (§12).

### 10.11 Settings (F3: `SettingsView`) — in the main window

Settings is a page in the main window's detail column (§10.1), not a separate window or a `TabView`.
```
  ┌ detail column ──────────────────────────────────────────────────────────────┐
  │ [⚙ General] [◐ Appearance] [▭ Overlay] [⌨ Shortcuts] [# Labels & Tags] …    │ ← PillTabBar, padding
  │─────────────────────────────────────────────────────────────────────────────│   XL h · L top · M bottom
  │            ┌ SettingsPage(maxWidth: 720), centred, top-aligned ┐            │ ← 1 pt separator
  │            │  Form { … }.formStyle(.grouped)                   │            │
  │            │                                                   │            │
  │            │  Automatic pausing                                │            │
  │            │  Pause when the Mac sleeps                  [on]  │            │
  │            │  Ask “Still working?” after 10 hours        [-|+] │ ← ValueStepper
  │            │                                                   │            │
  │            │  Goals & calendar                                 │            │
  │            │  Daily goal 4h                              [-|+] │            │
  │            │  Week starts on Monday ⌄                          │ ← ValuePicker
  │            └───────────────────────────────────────────────────┘            │
  └─────────────────────────────────────────────────────────────────────────────┘
```
(The icons in the bar are SF Symbols: `gearshape`, `paintpalette`, `rectangle.inset.topright.filled`,
`keyboard`, `tag`, `person.crop.circle`, `externaldrive`.)
- **Sections:** General, Appearance, Overlay, Shortcuts, Labels & Tags, Account, Data, switched by a
  `PillTabBar` (icon-only pills with tooltips when the column is narrow; scrolls only if even that doesn't fit). The selection persists
  (`settingsWindow.selectedTab`); `router.showSettings(tab:)` opens a given section.
- **Width:** each section is wrapped in `SettingsPage(maxWidth:)`: 720 for General, Appearance, Shortcuts,
  Account and Data; 760 for Overlay (room for the layout editor); full width (`nil`) for Labels & Tags (two
  columns). Forms fill that width; the page is centred and top-aligned on `themedBackground()`.
- **Value sentences:** a setting whose value is a number or a short choice reads as a sentence with the value
  **bold in the accent color**, in the same font and on the same baseline as the words around it, never
  monospaced: "Keep the latest **10 backups**", "Ask “Still working?” after **10 hours**", "Daily goal **4h**"
  (or **Off**), "Week starts on **Monday**", "Default label **Work**", "Back up **hourly**" (when off: "Automatic
  backups **Off**"), "Opacity **95%**", and the accent name in Appearance. Steppers and sliders
  stay native and sit trailing (`ValueStepper`, `ValueSlider`); short choices open a small list from the value
  itself (`ValuePicker`). Never put `LabeledContent` or monospaced digits inside a `Stepper` label: that splits
  the sentence into two columns and breaks the baseline.
- **Native controls stay** where they are clearer: segmented pickers (appearance mode, text size, Labels/Tags),
  toggles and pickers inside sheets. Default label and a tag's parent label use `LabelValuePicker`.
- **Footnotes** (`SettingsFootnote`) only where the effect isn't obvious: ≤ 1 sentence, ≤ ~15 words, no
  shortcut glyphs (§12.0).

**General:** New sessions (default label) · Takeaway · Automatic pausing · Goals & calendar · Menu bar
("Show in menu bar", "Show timer", "Show takeaway"; the last two disabled while the first is off) · Dock.

**Overlay** (F2): "Overlay" (Show overlay + a one-line status footnote "Showing" / "Hidden" / "Appears when a
session starts"; Hide when idle) · "Layout" (the editor, §10.6.1) · "Window" (Compact, `ValueSlider`
"Opacity", Keep on top, Show on all Spaces, "Restore Defaults").

**Shortcuts** (F3, `SettingsShortcutsTab`):
```
  Session
  Start / Stop Session                       [  ⇧⌘S  ]  ↺
  Pause / Resume                             [  ⇧⌘P  ]  ↺
  Discard Session                            [  None  ]  ↺ (disabled: default)
                                    Used by Start / Stop Session.   ← danger caption, trailing, 4 s
  Navigation
  Show Today                                 [  ⌘1   ]  ↺
  …
  Editing
  Find in History                            [  ⌘F   ]  ↺
  Save Session Review                        [  ⌘↩   ]  ↺

  ( Reset All )
  ⌘, ⌘Q, ⌘W, Esc, Return and ⌫ are fixed.
```
- One grouped `Section` per `ShortcutGroup`; rows are the action title, a `ShortcutRecorder` and a
  `ResetToDefaultButton` (a11y "Reset *Action*"). A rejected recording shows the store's message under the row
  in `captionFont` `danger` ("Include ⌘ or ⌃." / "Reserved by macOS." / "Use ⇧ with a letter." / "Used by *Action*.");
  resetting an action whose default another action had taken clears that other action and shows "Removed from
  *Action*." under the reset row in `textSecondary`; it clears after
  4 s or at the next attempt. "Reset All" (Quiet, disabled without customizations) confirms "Reset all
  shortcuts?". Changes apply immediately to menus, in-view shortcuts and the menu bar hint.

- Labels & Tags: two-column: label list (drag to reorder, `ColorDot` + symbol + name + usage count) /
  editor (name field, `LabelColorPicker`, `SymbolPicker` in a 240 pt area, Archive / Delete…). Tags below:
  `Table` or List with name, parent label `LabelValuePicker("Parent label", selection:)`, color, usage, ⋯.
- Delete label: sheet "Delete “Meetings”? 42 sessions use it. Move them to: ▾ [Unlabeled]" `{!Delete}`.
- Data: grouped sections Export / Import / Backups (list rows: date `shortDateTime` + `pin.fill` when pinned,
  "reason · N sessions · pinned", size in `monoFont`, Restore…, ⋯ menu with Pin/Unpin · Show in Finder · Delete…)
  / Danger zone (`DestructiveButtonStyle`, double confirm). Importing a file and restoring a backup both go
  through `BackupService` (`importArchive(_:mode:)` / `restore(from:mode:)`), which makes the safety backup first.
- Data: "Back up **hourly**" (`ValuePicker` over `BackupInterval`, values lowercased; when off the sentence reads
  "Automatic backups **Off**") and "Keep the latest
  **10 backups**" (`ValueStepper`).
- **Data ▸ Recovery** (only while the store couldn't be opened, i.e. in-memory mode): a first section with an
  error `InlineBanner` "Your data couldn’t be opened. Changes won’t be saved." and the
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
          Track focused work and keep what you learned.   ← bodyFont, textSecondary, centered, max 420

                   [  Sign in with Apple  ]           ← SignInWithAppleButton 260×36
                   ( Continue as Guest )             ← QuietButtonStyle

                          Theme                      ← sectionHeaderFont, textSecondary
         [Graphite ✓]     [Paper]     [Meadow]       ← ThemeSwatchRow() (compact swatches, 124 pt)

     Your data syncs with iCloud either way.           ← captionFont tertiary
                                                       (only when CloudKit is in use; see below)
                ( Recover… )  ( Settings… )           ← QuietButtonStyle; Recover… only in recovery mode
     [InlineBanner error …]                            (if auth.lastError)
```
Full-window `themedBackground()`, content vertically centered, no illustration, no gradients.
- The storage line is truthful: it mentions iCloud sync only when this launch actually uses CloudKit;
  otherwise "Your data is saved on this Mac." (+ where to turn sync on, or why iCloud isn't available).
- Theme picker: `ThemeSwatchRow()` — compact swatches show the theme in the current appearance with the
  name below (no tooltip; VoiceOver reads the summary). Clicking applies the theme immediately (the Welcome screen
  re-themes live), so the choice is self-explanatory. Graphite is preselected.
- Settings is reachable before signing in: **Settings…** calls `router.showSettings()` and RootView shows the
  Settings page full-window with a Back button. When the store couldn't be opened (`persistence.isRecoveryMode`)
  the storage line reads "Your data couldn’t be opened. Changes won’t be saved." and **Recover…** opens
  Settings ▸ Data (`router.showSettings(tab: "data")`).

---

## 11. Interaction details

- **Hover:** subtle fill (`textPrimary.opacity(0.05–0.07)`) on rows and icon buttons; buttons provided by
  the design system already react. No hover-only information (anything in a tooltip is also reachable).
- **Focus:** native focus rings for native controls; DS buttons draw an accent ring when focused; inset
  fields turn their border accent (`insetField(isFocused:)`). Use `@FocusState` for: Today note composer
  (router.noteFocusRequest), History search (Find in History), EndSessionSheet title, popover search fields.
- **Keyboard:** Return submits single-line fields; Esc cancels/closes (EndSessionSheet: Esc = Save as-is);
  ⌫ deletes selected History row (confirm); arrow keys move list selection; Space toggles focused
  checkbox/toggle. Every icon-only button has `.help` *and* `.accessibilityLabel`. App shortcuts are
  customizable (§11.1).
- **Context menus:** rows (History sessions, notes, segments, learning points, images) have a context menu
  that mirrors their ⋯ menu. Destructive items last, with `role: .destructive`.
- **Confirmations:** `confirmationDialog` for Discard / Delete / Replace import / Delete all (double).
  Titles state the consequence: "Delete this session? This can’t be undone."
- **Tooltips:** the action's name (§12.0); also on truncated titles (full text), timestamps ("Edited Oct 7,
  10:42") and chart segments.
- **Drag & drop:** image drop zones highlight with an accent dashed border (`StrokeStyle(dash: [5, 4])`)
  and `accent.opacity(0.06)` fill while targeted. Reordering (overlay layout editor) is live: items move
  while you drag, with an unrotated drag preview.

### 11.1 Shortcuts

**Customizable** (`ShortcutAction`, stored by `ShortcutStore` under `shortcuts.overrides`; Settings ▸ Shortcuts):

| Group | Action | Default |
|---|---|---|
| Session | Start / Stop Session · Pause / Resume · Add Note · Split Segment · Discard Session · Toggle Overlay | ⇧⌘S · ⇧⌘P · ⇧⌘N · ⇧⌘D · none · ⇧⌘O |
| Navigation | Show Today · Show History · Show Learning · Show Stats | ⌘1 · ⌘2 · ⌘3 · ⌘4 |
| Editing | Find in History · Save Session Review | ⌘F · ⌘↩ |

**Fixed** (HIG/system conventions that users and VoiceOver rely on; mostly scoped to focus or a dialog, several
owned by AppKit): ⌘, Settings · ⌘Q, ⌘H, ⌥⌘H, ⌘W, ⌘M, full screen (⌃⌘F), ⌃⌘S Toggle Sidebar · the Edit menu
(⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A) · Help (⇧⌘/) · Return (`.defaultAction`) and Esc (`.cancelAction`) in sheets and popovers
· Return in text fields · ⌫ in the History list · ←/→ in the image viewer. These combinations are reserved:
recording one gives "Reserved by macOS.".

**Rules for a recorded shortcut:** it must include ⌘ or ⌃ ("Include ⌘ or ⌃."), must not be reserved, and
must not duplicate another action ("Used by *Action*."). Letters are stored lowercase; ⇧ is an explicit
modifier. Glyph order is ⌃⌥⇧⌘ + key.

**`ShortcutRecorder`** (the key-cap field):
- **Idle:** the shortcut in a key-cap pill (`insetSurface`, `separator` border, `radiusS`, `bodyFont` medium,
  min width 96, height 24), or "None" in `textTertiary`. Help "Record shortcut".
- **Click → recording:** 1.5 pt accent border, "Type shortcut…" in `textSecondary`; held modifiers show live
  ("⌥⌘") while you hold them. Help "Esc cancels, ⌫ clears". The pill keeps its width, so the row doesn't
  shift.
- While recording, a local `NSEvent` monitor swallows every key (including ⌘Q): **Esc** (no modifiers)
  cancels; **⌫ / ⌦** (no modifiers) clears the shortcut; any other supported key combination is handed to
  `onRecord` and validated by the store; unsupported keys (F-keys, keypad-only) beep and keep recording.
- Recording ends on a second click, a click anywhere else (the click goes through), the window resigning
  key, the field disappearing, or another recorder starting (one at a time). The monitor is removed on
  every exit path.
- VoiceOver: label = the action's title, value = the shortcut ("None" / "Recording"), hint "Records a new
  shortcut."

**Where glyphs appear:** only in menus (automatic), the menu bar panel's hint column and Settings ▸ Shortcuts.
Never in tooltips, button titles, footnotes or empty states (§12.0).

## 12. Copy

### 12.0 Copy guideline

Voice: plain, short, sentence case, no exclamation marks, no emoji. Name the next step. Every string in the app
follows these rules.

1. **Tooltips (`.help`)**
   - Use the action's name: 1–3 words, sentence case, no trailing period, no colon explanations, no shortcut glyphs.
     - "Split segment", "Pause", "Resume", "Stop", "Discard", "Hide overlay", "Add images", "More", "Reset", "Search".
   - Only exception: a disabled control may say why, in ≤ 6 words ("Stop the session first").
   - Tooltips on truncated text may show the full text.
2. **Button titles**
   - A verb, or verb + noun, ≤ 3 words.
   - Add "…" only when more input or confirmation follows ("Restore…", "Delete…").
3. **Helper text / footnotes (`SettingsFootnote`, captions)**
   - Only when the effect isn't obvious from the label.
   - ≤ 1 sentence and ≤ ~15 words.
   - Delete footnotes that restate their label or list where else a feature appears.
4. **Empty states**
   - Title ≤ 4 words.
   - Message optional, ≤ 1 sentence and ≤ 10 words.
   - Action ≤ 3 words.
5. **Banners:** ≤ 1 short sentence + an action.
6. **Confirmation dialogs**
   - Title states the consequence in ≤ 8 words.
   - Message optional, ≤ 1 sentence.
7. **Accessibility labels:** the control's name; it may be slightly more specific than the tooltip ("Discard session").
8. **Accessibility hints:** only when the result isn't implied by the label; ≤ 1 short sentence.
9. **Shortcut glyphs**
   - Never hard-code a shortcut glyph anywhere except fixed system ones (⌘, and ⌘Q).
   - Glyphs appear only in:
     - menus (automatic)
     - the menu bar panel's hint column, which reads `ShortcutStore.displayString(for:)`
     - Settings ▸ Shortcuts
10. **Section headers:** 1–2 words.

**Canonical rewrites.** Use these exact strings; the same pattern applies elsewhere.

| Before | After |
|---|---|
| `Split segment: start a new one now` (OverlayView) | `Split segment` |
| `Close the current segment and start a new one now` (LiveSegmentForm) | `Split segment` |
| `Start a new segment when your focus changes (⌘⇧D)` | `Split segment` |
| `Stop and review the session (⌘⇧S)` | `Stop` |
| `Resume the session (⌘⇧P)` / `Pause the session (⌘⇧P)` | `Resume` / `Pause` |
| `Start a session with this label, tags and focus (⌘⇧S starts with the default label)` | `Start session` |
| `Start a session with the chosen label (⌘⇧S)` | `Start session` |
| `Start a session with “X” (the default label)` | `Start session` |
| `Hide overlay (⌘⇧O)` | `Hide overlay` |
| `Attach images to this session (you can also drop or paste them here)` | `Add images` |
| `Attach images from your Mac. You can also paste or drop images on Images below.` | `Add images` |
| `Done: stop showing this takeaway` | `Done` |
| `Keep tracking; the time since you stopped counts as a pause` | `Resume session` |
| `Save session (⌘↩)` | `Save` |
| `Search titles, notes, labels, tags, focus and learnings (⌘F)` | `Search` |
| `This session was started or last changed on another Mac. Pausing, splitting or stopping it here takes it over.` | `Running on another Mac` |
| `Primary label (segments that used the old label follow)` | `Label` |
| `Showing X` / `Show X` (History chips) | `X` (chip help) |
| Footnote `Used when you start from the menu bar, the overlay or ⌘⇧S. “None” uses the first label in your list.` | `“None” uses your first label.` |
| Footnote (Import) `Import a Worklog JSON export or backup. “Merge” adds …` | `Replace deletes current data first. A backup is made either way.` |
| Footnote (Takeaway) | `Shown until the next session’s review.` / `Shown until replaced or marked done.` |
| Footnote (Automatic pausing) | `Worklog never resumes on its own.` |
| Overlay status `Hidden. Turn it on here, from the menu bar panel or with ⌘⇧O.` | `Hidden` / `Showing` / `Appears when a session starts` |

**Sweep** (run over your files before handing off; fix every hit that breaks the rules):
```
grep -n '\.help(\|Text("\|Label("\|Button("\|SettingsFootnote(\|EmptyStateView(\|InlineBanner(\|accessibilityHint(\|confirmationDialog(\|message:\|⌘' <your files>
```

### 12.1 Empty states

| Where | `EmptyStateView` title / systemImage / message / action |
|---|---|
| History, no sessions | "No sessions yet" / `clock` / "Finished sessions appear here." / "Start session" → Today |
| History, no results | "No matches" / `magnifyingglass` / "Nothing matches “\(q)”." / "Clear filters" (only with chip filters) |
| History, nothing selected | "Select a session" / `sidebar.left` / – / – |
| History, live session selected | "Session in progress" / `timer` / – / "Go to Today" |
| Learning, no learnings | "No learnings yet" / `lightbulb` / "Add learning points when a session ends." / – |
| Learning, no tags | "No tagged learnings" / `number` / "Tag points to follow a topic." / – |
| Learning, no search results | "No matches" / `magnifyingglass` / – / – |
| Stats, not enough data | "Not enough data" / `chart.bar.xaxis` / "Finish a session in this range." / – |
| Labels, none | "No labels" / `tag` / – / "Restore defaults" |
| Session detail, no notes | inline `textTertiary`: "No notes." |
| Session detail, no images | inline: "Drop, paste or add images." |
| Today, nothing logged | inline: "Nothing logged today." |
| Overlay / menu, no takeaway | omit the section entirely |

### 12.2 Banners and dialogs

Banners (`InlineBanner`, ≤ 1 short sentence + an action):
- in-memory store (error): "Your data couldn’t be opened. Changes won’t be saved." · "Restore…"
- iCloud sync error (warning): "iCloud sync failed; changes kept on this Mac." · "Details…"
- auto-pause (warning): "Paused while your Mac slept." / "Paused when Worklog quit." · "Resume"
- long session (warning): "Running for \(n) hours. Still working?" · "Stop at last activity" / "Stop now" /
  "Keep going"
- short session, end sheet (warning): "Under a minute long." · "Discard"

Confirmation dialogs (title = the consequence, ≤ 8 words; message optional, ≤ 1 sentence):
- "Delete this session?" · "This can’t be undone."
- "Discard this session?" · "Its notes and time will be deleted."
- "Reset all shortcuts?"

## 13. Accessibility

- **Contrast:** `textPrimary` and `textSecondary` meet ≥ 4.5:1 on `background`/`surface` in every theme and
  scheme; `textTertiary` (≥ 3:1 on background/surface) is for non-essential metadata only. `onAccent` meets ≥ 4.5:1 on the theme
  default accents; accent overrides pick dark/white text by contrast.
- **Color is never the only signal:** badges show names; paused shows "Paused"/pause glyph; selected chips
  have a border; the selected swatch has a ring and the `.isSelected` trait.
- **VoiceOver:** TimerText → label "Elapsed time", value "1 hour, 12 minutes, 40 seconds[, paused]".
  LiveDot → "Running"/"Paused". LabelBadge → "Label: Deep work". TagChip → "Tag: coding" (+ "Remove tag
  coding" button). SectionHeader has the header trait. FilterChip / PillTabBar buttons carry `.isSelected`.
  Value rows (`ValueStepper`/`ValueSlider`) are one adjustable element ("Keep the latest backups", value "10
  backups"). Edit-mode badges are labelled with the element ("Remove Timer", "Add element") and every
  drag-reorder has "Move Up"/"Move Down" actions. Charts: add `.accessibilityLabel` per mark
  ("Monday, Deep work, 2 hours") and a summary label on the chart.
- **Text size:** Settings ▸ Appearance ▸ Text size scales every theme font (0.92–1.25). Layouts must not
  clip at Extra Large: use `fixedSize(horizontal: false, vertical: true)` for wrapping text, avoid fixed
  heights on text containers (the overlay/menu panel have fixed *widths* only).
- **Keyboard:** everything reachable without a mouse (see §11). Custom buttons are real `Button`s.
- **Reduce Motion / Transparency:** honor `accessibilityReduceMotion` (DS components already do; the
  edit-mode wiggle becomes a dashed outline).
  `themedPanelBackground` switches from the material to solid `elevatedSurface` when Reduce Transparency
  is on; if you fill a panel yourself, check `@Environment(\.accessibilityReduceTransparency)` too.

## 14. Do / Don't (quick checklist for feature code)

- Do read `@Environment(\.theme)`; don't use `Color.blue`, `.font(.title)`, magic paddings or radii.
- Do use `label.color` / `tag.color`; don't invent label colors.
- Do wrap running timers in `TimelineView(.periodic(from: .now, by: 1))`; don't use `engine.tick` (menu bar label only).
- Do use one `PrimaryButtonStyle` per region; don't make destructive buttons filled.
- Do use native `Form`, `Picker`, `Toggle`, `DatePicker`, `List`; don't re-skin them.
- Do give icon-only buttons `.help` + `.accessibilityLabel`; keep tooltips to the action's name (§12.0).
- Don't hard-code shortcut glyphs (read `ShortcutStore`); don't nest `HSplitView` in the main split view;
  don't let data-dependent content set a pane's minimum size.
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
