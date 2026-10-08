# Worklog — Design (docs/DESIGN.md)

> Owner: **DES**. This is the design language and the screen-by-screen UX spec for feature programmers
> **A** (live session, end-session sheet, menu bar, overlay), **B** (history, session detail, learnings
> editor) and **C** (learning, stats, settings, welcome). The API contract is `docs/ARCHITECTURE.md` §4;
> this document says **how to use it**. Where the two disagree on a signature, ARCHITECTURE.md wins.
>
> **Round 2** is folded in: Settings lives in the main window (§10.1, §10.11), app shortcuts are customizable
> (§11.1), the overlay has an editable layout (§10.6), and all copy follows the guideline in §12.0.
>
> **Round 3 (Profiles)** is specified in §16: the sidebar profile switcher, `ProfileBadge`, the profile pickers
> and the `profileID:` scoping of every label/tag picker. Where §16 and an earlier section disagree, §16 wins.
>
> **Round 4** (§17): the profile switcher expands an inline list instead of a popover (§16.4), the edit badges
> are smaller and top-trailing (§8.1), and the overlay layout is a 6-column grid (§10.6).

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
  marks the editable items instead. Adding, removing, dropping and resizing grid elements animates 150 ms
  ease-out (`nil` under Reduce Motion); the drag ghost and the floating copy are never animated.
- **Sidebar profile list** (`ProfileSwitcher`): expands and collapses 180 ms ease-out (the list slides up from
  behind the row and fades; it only fades out), and the chevron rotates 180° with it. No animation under
  Reduce Motion.
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
| `RemoveBadgeButton` | `RemoveBadgeButton(accessibilityLabel: String, action: () -> Void)`; statics `diameter` 14, `hitSize` 22, `cornerOffset` (8, −8) | Edit-mode (−): 14 pt `danger` circle, white `minus` (7 pt bold), 1.5 pt `elevatedSurface` ring (17 pt), 22 × 22 pt hit area, 20 pt accent focus ring, help "Remove". Don't place it by hand: use `editRemoveBadge`. |
| `View.editRemoveBadge(_:accessibilityLabel:action:)` | `func editRemoveBadge(_ isShown: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View` | The (−) badge on the item's **top-trailing** corner: `overlay(alignment: .topTrailing)` + `cornerOffset`, so the badge centre sits 3 pt inside the corner and the circle overhangs 4 pt. Apply it after `.wiggle` so the badge doesn't rotate. |
| `EditResizeHandle` | `EditResizeHandle()`; statics `hitSize` 20 × 24, `edgeOffset` 8 | Edit-mode resize handle on the item's trailing edge (`overlay(alignment: .trailing)` + `.offset(x: edgeOffset)`: capsule centre 2 pt inside the edge). 4 × 14 pt accent capsule, 1.5 pt `elevatedSurface` ring, hover 0.88, `NSCursor.resizeLeftRight` while hovered (push/pop balanced), help "Resize", hidden from VoiceOver (the item's "Wider"/"Narrower" actions replace it). Visual only: the feature attaches the drag gesture. |
| `AddBadgeButton` | `AddBadgeButton(accessibilityLabel: String, action: () -> Void)` | Edit-mode (+): 24 pt accent circle, `onAccent` `plus` (11 pt bold), 28 pt hit area, help "Add" (dropped while disabled so the caller's reason shows, e.g. "All elements shown"). Standalone, under the preview. |
| `View.wiggle(_:seed:)` | `func wiggle(_ isActive: Bool, seed: Int = 0) -> some View` | Edit-mode wiggle (§7). The view keeps its identity when edit mode toggles. |

## 9. Shared data-bound controls (`Worklog/Shared`)

| Control | Behavior |
|---|---|
| `LabelPicker(selection:includeNone:title:profileID:)` | Native pop-up `Picker` (`.menu`): "None", divider, the non-archived labels **offered in `profileID`** (global + local to it, §16.3) by `sortIndex` with colored symbol; an archived current selection is listed as "Name (archived)", a current selection local to another profile as "Name (Personal)". Shows its `title` on the left; use `.labelsHidden()` in compact places. |
| `LabelValuePicker(_:selection:profileID:)` | Settings value sentence over labels ("Default label **Work ⌄**", "Parent label **None ⌄**"): a `ValuePicker` with "None" + the same options as `LabelPicker`; a deleted selection reads "None" and nil is written back. |
| `TagPicker(selection:scopeLabel:profileID:allowsCreate:)` | Selected tags as removable chips + a dashed "+ Add tag" chip that opens a popover: search field (focused), **scope label's tags**, **Any label** (tags without a parent label), while searching **Other labels**, and selected tags of other profiles under **Other profiles**; only tags offered in `profileID` are listed otherwise. Rows toggle (multi-select, popover stays open); "Create “x”" creates a tag **local to `profileID`'s profile** (global when nil) via `TaxonomyOps.createTag(name:profile:in:)` and selects it. Return = toggle exact/only match or create. Bind with `$session.tagList`, `$segment.tagList`, `$point.tagList`. The picker does not call `touch()`. |
| `TagChipsRow(tags:)` | Read-only chips; renders nothing when empty. |
| `NoteRow(note:showsSegment:)` | `10:42` (caption, tabular, tertiary) · selectable body text (6 lines + "Show more") · optional segment caption (dot + focus) · "Edited". Read-only; add `.contextMenu` (Edit / Change time / Delete) in your feature. |
| `LabelColorPicker(hex:)` | 15 swatches (wrapping) + system color well for custom; selected ring. |
| `SymbolPicker(symbolName:)` / `SymbolPicker(symbolName:symbols:)` | Adaptive grid (30 pt cells) of `LabelPalette.symbols` (or the given list, e.g. `LabelPalette.profileSymbolChoices`); current custom symbol shown first. Put it in a popover or a fixed-height area (~240 pt). |
| `ProfileBadge`, `ProfileSwitcher`, `ProfileCreateSheet`, `ProfilePicker`, `ProfileValuePicker`, `ProfileSymbolTile` | Round 3, see §16.2. |

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
**Layout model (round 4: a grid).** The overlay is a **6-column grid** of elements,
`AppSettings.overlayGrid: OverlayGridLayout` (ARCHITECTURE §13). Each element has one cell: a row, a starting
column and a **span** of 1–6 columns; elements are always one row high. Elements: Label, Timer, Segment focus,
Controls, Split, Today’s total, Quick note, Takeaway.
- **Columns** span the content width (276 pt regular, 204 compact) with a `spacingXS` (4 pt) gutter, so spans
  1 / 2 / 3 / 6 are 42.7 / 89.3 / 136 / 276 pt (compact 30.7 / 65.3 / 100 / 204). Free columns stay empty space.
- **Rows** are as tall as their tallest element; row spacing as before (`spacingS`, compact `spacingXS + 2`).
  **Row 0 is the header row** (the model's index; VoiceOver and copy count it as row 1), inline between the dot and the profile tag / close button (with its own 6
  narrower columns). It may be empty; then the status word shows there. Empty body rows never persist.
- **Spans:** default / minimum per element — Label 4 / 2, Timer 6 / 3, Segment focus 6 / 3, Controls 2 / 2,
  Split 1 / 1, Today’s total 2 / 2, Quick note 6 / 3, Takeaway 6 / 3. Every minimum fits at compact width.
- **Default** (fresh install and "Reset Layout"): Label in the header row (columns 1–4); Timer; Segment focus; Controls +
  Split side by side; Quick note; Takeaway (each full-width on its own row). Upgraded layouts keep their
  elements and reading order (inline runs share a row, Today’s total trailing). An empty grid is allowed: only
  the header shows.
- **Compact** uses the same placements on the narrower grid, with the elements in their compact styles.
```
  Regular, default grid                     Split removed, Today's total added with (+)
  ╭──────────────────────────────────╮      ╭──────────────────────────────────╮
  │ ● [◉ Deep work      ]          ✕ │      │ ● [◉ Deep work      ]          ✕ │  ← row 0 = header row
  │ [1:12:40                       ] │      │ [1:12:40                       ] │
  │ [Refactor parser · seg 24:10   ] │      │ [Refactor parser · seg 24:10   ] │
  │ [⏸ ■][✂]                         │      │ [⏸ ■]             [Today 2h 15m] │  ← free columns stay space
  │ [ Note…                        ] │      │ [ Note…                        ] │
  │ [“ Batch review comments…      ] │      │ [“ Batch review comments…      ] │
  ╰──────────────────────────────────╯      ╰──────────────────────────────────╯
```

**Rendering** (one renderer, `OverlayContent`, for the live overlay, the preview and the editor):
- Background: `themedPanelBackground(cornerRadius: theme.radiusL)`; padding `spacingM` (compact `spacingS`).
- **Header chrome** (always there, not an element, can't be removed): `LiveDot` (idle: `timer` glyph), then the
  header row's elements, or a status word ("Running" / "Paused" / "Not tracking") when none of them is visible;
  close `xmark` top-trailing, `IconButtonStyle(size: 18)`, help "Hide overlay".
- **In a cell:** "fill" elements (Timer, Segment focus, Quick note, Takeaway, idle Controls) take the cell width;
  "hug" elements (Label, active Controls, Split, Today’s total) align **trailing** when they end at the last column and
  don't start at the first, otherwise leading. Elements truncate instead of overflowing (Today’s total drops to
  "2h 15m", the timer to its compact style); cells are never clipped, so badges and focus rings show.
- Rows with nothing visible collapse (live and preview).
- Controls: pause/resume + stop, `IconButtonStyle(size: 26)` (22 compact), help "Pause"/"Resume", "Stop".
  Split: `scissors`, help "Split segment".
- **Idle:** the header shows "Not tracking"; the header row's idle-visible elements become the first body row.
  Visible: Takeaway (with Done ✓), Today’s total and Controls (as "Review…" when a review is pending, plus
  `[ ▶ Start · Deep work ]`, help "Start session"), in grid order; Controls widen over the free columns of their
  row. The rest is hidden.
- "Running on another Mac" is chrome under the header, live only.
- Whole panel is draggable (window background); the live overlay has no gestures on elements.

#### 10.6.1 Layout editor (Settings ▸ Overlay ▸ Layout, F2: `OverlayLayoutEditor`)

Direct manipulation, in the spirit of iPhone Control Center: what you see is the overlay, at real size.
```
  ┌ Layout ────────────────────────────────────────────────────────────┐
  │ [ Running | Idle ]                    ( Reset Layout )  [ Done ]   │  ← header row (editing)
  │ ┌ stage: insetSurface, radiusM, padding spacingXL, min height 200 ┐ │
  │ │   (the preview at real size: the overlay grid, mid-drag)        │ │
  │ │        (+)                              ← AddBadgeButton        │ │
  │ └─────────────────────────────────────────────────────────────────┘ │
  │ Drag to move; drag the right edge to resize.                       │  ← SettingsFootnote
  └────────────────────────────────────────────────────────────────────┘

  Mid-drag: Controls dragged onto the Timer's row, columns 1–2
  ╭─────────────────────────────────────╮
  │ ● [◉ Deep work         ]⊖         ✕ │   ⊖  (−) badge, top-trailing
  │ ┌╌╌╌╌╌╌╌┐▒▒▒ 1:12:40 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒┃ │   ┃  resize handle, trailing edge
  │ └╌╌╌╌╌╌╌┘                           │   ┌╌┐ snap ghost (dashed accent, fill 0.08)
  │ [Refactor parser · seg 24:10     ]⊖┃│   ▒  dimmed 0.5: the Timer will move to a new row below
  │ ⋯⋯⋯⋯⋯⋯⋯⋯[✂]⊖┃                       │   ⋯  the dragged Controls, left in place at 0.35
  │ [ Note…        ╭──────────╮      ]⊖┃│   ╭─╮ floating copy (0.9, 1 pt accent border, unrotated)
  │                │  ⏸  ■    │         │
  ╰────────────────╰──────────╯─────────╯
```
- **At rest:** a non-interactive preview (`allowsHitTesting(false)`, nothing touches the engine) with a
  segmented "Running / Idle" preview switch (small) and an "Edit" button (`QuietButtonStyle`).
- **Edit** → the preview always shows the running sample with every grid element; the header row shows
  "Reset Layout" (Quiet, disabled at the default) and "Done" (`PrimaryButtonStyle`) instead. The footnote
  "Drag to move; drag the right edge to resize." sits under the stage.
  - Each element **wiggles** (`.wiggle(true, seed: index)`; dashed outline under Reduce Motion), then gets the
    **(−)** badge on its top-trailing corner (`editRemoveBadge`, a11y "Remove *Element*") and the
    `EditResizeHandle` on its trailing edge. The header chrome doesn't wiggle and can't be removed or moved.
  - **Drag to move** (anywhere on the element, 2 pt minimum distance so clicks and right-clicks still work):
    the element stays in place at 0.35 opacity; a **floating copy** (0.9 opacity, 1 pt accent border, `radiusS`,
    unrotated, no shadow) follows the pointer; a **snap ghost** (dashed 1 pt accent `radiusS` stroke, accent fill
    0.08) shows the target cell — the column under the copy's leading edge, the row under its vertical centre.
    Elements that would be pushed down dim to 0.5. While dragging, an empty drop row appears under the last row.
  - **Drop:** the element snaps into the cell (150 ms ease-out, none under Reduce Motion). Elements it overlaps
    move together into a new row directly below, keeping their columns; a row left empty disappears. Releasing
    more than 40 pt outside the panel cancels and snaps back.
  - **Resize:** drag the trailing handle; the span changes in column steps, clamped to the element's minimum
    and to its right-hand neighbour (resizing never pushes). Height can't be resized.
  - **(+)** `AddBadgeButton` (a11y "Add element") under the preview opens a popover listing the hidden
    elements (icon + title); clicking one puts it in the first free body cell (Today’s total prefers the
    trailing end); the popover closes when none are left. With everything shown the button is disabled with
    help "All elements shown".
  - **Keyboard / VoiceOver:** each element is focusable while editing (accent focus ring, `radiusS`, 2 pt).
    ←/→/↑/↓ move, ⇧← narrower, ⇧→ wider, Delete/⌫ removes. The context menu and accessibility actions offer
    "Move Left", "Move Right", "Move Up", "Move Down", "Wider", "Narrower", "Remove" (actions: only the ones that
    apply; menu: inapplicable ones disabled). VoiceOver reads the title and the cell as the value, 1-based with the header
    row as row 1: "Row 1, columns 1–4" (or "Row 3, column 3" for one column).
- Every change writes `settings.overlayGrid` immediately; the real overlay updates live. "Done" only leaves
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
  and `accent.opacity(0.06)` fill while targeted. The overlay layout editor snaps instead (§10.6.1): an
  unrotated floating copy follows the pointer, a dashed snap ghost shows the target cell, and the grid changes
  only on drop.

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
  backups"). Edit-mode badges are labelled with the element ("Remove Timer", "Add element"), every
  drag-reorder has "Move Up"/"Move Down" actions, and overlay grid elements add "Move Left"/"Move Right",
  "Wider"/"Narrower" (the resize handle itself is hidden). Charts: add `.accessibilityLabel` per mark
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

---

## 16. Round 3: Profiles

A **profile** ("Work", "Personal", …) is an independent context: its own sessions, its own local labels and
tags, its own takeaway and stats. Global labels and tags (`profile == nil`) are offered in every profile. The
contracts (models, `ProfileStore`, `ProfileScope`, `ProfileOps`) are in ARCHITECTURE §12; this section is the
visual and interaction spec. The UI stays quiet with one profile: badges only appear with **2 or more** profiles
(`profiles.hasMultipleProfiles`). The sidebar switcher is the exception, because it is where profiles are created.

### 16.1 Visual language

- **A profile is not a label.** A label is a chip (tinted capsule, `LabelBadge`). A profile is its SF Symbol in
  the profile color followed by its name, with no fill and no outline (`ProfileBadge`). The only filled
  profile shape is the **tile**: an 18 pt rounded square (`radiusS`) filled with `profile.color.opacity(0.18)`,
  with the symbol in the profile color (`ProfileSymbolTile`). Use it in the switcher and in profile lists.
- **Color** comes from `profile.color` (`DesignSystem/Model+Color.swift`; a deleted profile yields the neutral
  tag gray). Profile colors use `LabelPalette.swatches`, like labels. New profiles default to the first palette
  color no other profile uses.
- **Symbols:** `LabelPalette.profileSymbols` (briefcase, house, person, graduation cap, building, hammer, heart,
  star, leaf, laptop) come first in pickers; `LabelPalette.profileSymbolChoices` appends every label symbol.
  The default is `briefcase.fill`.
- **"No profile"** (a nil or deleted profile): `circle.dashed` in `textTertiary`, name "No profile" in
  `textSecondary`. Unassigned sessions are repaired automatically, so this is rare and transient.
- **Global items** (labels and tags offered in every profile) carry a trailing `globe` icon (`textTertiary`,
  help "All profiles") in Settings ▸ Labels & Tags only. Pickers don't mark them.

### 16.2 Components (`Worklog/Shared`)

| Component | Signature | Look and behaviour |
|---|---|---|
| `ProfileBadge` | `ProfileBadge(profile: WorkProfile?, size: BadgeSize = .small)`, `ProfileBadge(name:colorHex:symbolName:size:)` | Symbol (profile color) + name, one line, tail truncation. `.small`: `captionFont`, `textSecondary`, 10 pt symbol. `.regular`: `calloutFont`, `textPrimary`, 12 pt. `.large`: `headlineFont`, `textPrimary`, 14 pt. The value init is for snapshots that must not hold a model (overlay data, popovers). a11y: label "Profile", value = name. |
| `ProfileSymbolTile` (extra) | `ProfileSymbolTile(colorHex:symbolName:side: = 18)`, `ProfileSymbolTile(profile:side:)` | The tile of §16.1. Decorative (hidden from VoiceOver); pair it with the name. |
| `ProfileSwitcher` | `ProfileSwitcher(isExpanded: Binding<Bool>, maxMenuHeight: CGFloat)`, `ProfileSwitcher()` (own state, limit 280), `static func menuHeightLimit(sidebarHeight:) -> CGFloat` | Sidebar row with an inline profile list, see §16.4. `RootView` owns `isExpanded` (so clicks elsewhere in the sidebar collapse it) and passes `menuHeightLimit(sidebarHeight:)` = `min(360, max(120, sidebarHeight × 0.5))`. Reads `ProfileStore`, `WindowRouter` and the theme from the environment. |
| `ProfileCreateSheet` | `ProfileCreateSheet(selectsNewProfile: Bool = true)` | "New profile" sheet, see §16.4. Reads `ProfileStore`. Settings ▸ Profiles passes `selectsNewProfile: false`. |
| `ProfilePicker` | `ProfilePicker(selection: Binding<UUID?>, title: String = "Profile")` | Native `.menu` `Picker` over the non-archived profiles (+ an archived current selection as "Name (archived)"), tagged by UUID, symbols in color (`LabelMenuIcon`). An unresolved selection shows "No profile"; nil is never written. Session detail's profile row (the caller confirms and moves in the binding's setter). Reads `ProfileStore`. |
| `ProfileValuePicker` | `ProfileValuePicker(_ prefix: String, selection: Binding<UUID?>, nilTitle: String)` | Value sentence ("Quick start in **Current profile ⌄**"): options nil (= `nilTitle`) + the non-archived profiles. A selection that no longer resolves reads as `nilTitle` and nil is written back (only once profiles are loaded). Reads `ProfileStore`. |
| `LabelPicker` | `LabelPicker(selection:includeNone:title:profileID:)` | `profileID` is required: see §16.3. |
| `LabelValuePicker` | `LabelValuePicker(_:selection:profileID:globalOnly: = false)` | Same scoping. `globalOnly` offers only global labels (a global tag's parent label); a local selection stays listed as "Name (Work)". |
| `TagPicker` | `TagPicker(selection:scopeLabel:profileID:allowsCreate:)` | Same scoping; "Create “x”" makes a tag local to that profile. |
| `ScopedItemTitle` (extra) | `ScopedItemTitle.title(for: WorkLabel/WorkTag, in: ProfileScope) -> String`, `.foreignProfileName(of: WorkTag, in:)` | The option titles the pickers use: "Name", "Name (Personal)" (not offered here), "Name (archived)". Use it if a feature builds its own label/tag menu (e.g. `LiveTagMenu`). |
| `SymbolPicker` | `+ init(symbolName:symbols:)` | Pass `LabelPalette.profileSymbolChoices` in profile editors. |

### 16.3 Picker scoping (labels and tags)

Pass the profile whose items should be offered, never read the store inside the picker:

| Where | `profileID:` |
|---|---|
| Today idle start form, Settings ▸ Labels & Tags (parent label) | `profiles.activeProfileID` |
| Today active (segment form, tag menu), end-of-session sheet, Session detail, segment editors, split sheet, LearningsEditor | `session.profile?.uuid` (`engine.activeSessionProfileID` for the live session) |
| Menu bar panel and overlay start pickers | `profiles.quickStartProfileID` (the panel profile) |
| Settings ▸ Profiles default label | `profile.uuid` |

Rules (all pickers):
- **Offered** = live, non-archived, and `ProfileScope(profileID:).offers(_:)`: global, or local to that profile.
  Other profiles' local items are never offered. `profileID == nil` offers everything (a store without
  profiles degrades gracefully).
- A **current selection that isn't offered** stays visible so the control never lies: `LabelPicker` and
  `LabelValuePicker` list it as "Name (Personal)"; `TagPicker` keeps its chip and lists it under **Other
  profiles** with the profile name trailing, so it can be removed. Archived selections keep "(archived)".
- **Deleted models** are still never read: a deleted label selection becomes nil, deleted tags are dropped,
  and the cleaned value is written back (§9).
- **Creating a tag** from `TagPicker` resolves the profile in the action (`ProfileOps.profile(withID:in:)`) and
  calls `TaxonomyOps.createTag(name:profile:in:)`: the tag is local to that profile, or global with no profile.
  A same-name tag already offered there is reused.
- In the tag popover the section for tags without a parent label is titled **Any label** (was "Global"), so
  "global" only ever means "all profiles".

### 16.4 Screens

**Sidebar switcher** (`ProfileSwitcher`, placed by `RootView` between the mini status row and the footer;
padding h `spacingS`, v `spacingXS`). Round 4: the popover is gone; the row **expands an inline list** directly
above itself, inside the same bottom inset.
```
│ ● 1:12:40  ◉ Deep work  │  ← mini status row (only while a session runs; moves up while the list is open)
│─────────────────────────│
│ ╭─────────────────────╮ │  ← inline list: fill textPrimary.opacity(0.04), radiusM, 1 pt separator stroke,
│ │ ✓ ▣ Work            │ │    padding spacingXS; no shadow, no elevatedSurface
│ │   ▣ Personal        │ │  ← non-archived profiles; checkmark = current (scroll over the height limit)
│ │ ─────────────────── │ │
│ │   ＋ New Profile…    │ │  → ProfileCreateSheet, right away (sheet from the switcher)
│ │   ⚙ Manage Profiles… │ │  → Settings ▸ Profiles
│ ╰─────────────────────╯ │  ← gap spacingXS
│ ▣ Work              ⌃   │  ← ProfileSwitcher: tile · name (calloutFont medium) · chevron.up (⌄ while open)
│─────────────────────────│
│ ◯ Guest              ⚙  │  ← footer (account + Settings gear); never moves
```
- **Row:** a full-width plain button: 6 × 5 pt padding, `radiusS` fill `textPrimary.opacity(0.06)` on hover and
  while expanded, 0.10 pressed, accent focus ring. Name `textPrimary`, one line; `chevron.up` 9 pt semibold
  `textTertiary`, rotated 180° while expanded. Help "Switch profile". VoiceOver: label "Profile", value = name,
  hint "Shows the profile list." / "Hides the profile list.".
- **Expanding** grows the sidebar's bottom inset upward: the sidebar list gets shorter and the mini status row
  moves up; the footer stays put. 180 ms ease-out: the list slides up from behind the row and fades in, and only
  fades out (it is clipped, so it never draws over the row). No animation under Reduce Motion.
- **List rows** (unchanged from the popover): checkmark slot, `ProfileSymbolTile`, name in `bodyFont` (one line,
  tail truncation), each row 18 pt × `textScale` + 2 × 4 pt. Hover or ↑/↓ highlights
  (`textPrimary.opacity(0.07)`), pressed accent 0.18. The highlight starts on the current profile.
- **Collapses on:** picking a profile (`profiles.select(id:)`), Esc, clicking the row again, a click anywhere else
  in the sidebar list (that click only collapses, like a macOS menu), the mini status row, the account button or
  the gear (each collapses first), any sidebar selection change, and leaving Welcome. Clicks in the detail pane
  don't collapse it: it is inline, not modal.
- **"New Profile…"** collapses and presents the sheet immediately. **"Manage Profiles…"** collapses and opens
  Settings ▸ Profiles.
- **Keyboard:** expanding moves focus into the list (no focus ring; the highlight shows the position). ↑/↓ move,
  Return or Space picks, Esc collapses and returns focus to the row (with Full Keyboard Access).
- **VoiceOver:** the list is a container labelled "Profiles"; VoiceOver focus lands on the current profile's row,
  which carries `.isSelected`. The escape gesture collapses.
- **Height limit:** `maxMenuHeight` from `ProfileSwitcher.menuHeightLimit(sidebarHeight:)`
  (`min(360, max(120, sidebarHeight × 0.5))`, measured, never derived from data). The actions block (two rows,
  divider, padding) always shows; the profile rows that fit above it show in a plain stack, and only when there
  are more do they scroll (highlight kept visible). A short list is never padded out. At the 600 pt minimum
  window height the footer stays on screen and the window minimum doesn't grow.
- Picking a profile re-scopes every page in place. A running session keeps running in its own profile.

**New profile sheet** (`ProfileCreateSheet`, width 420, padding `spacingXL`):
```
  New profile                                   ← titleFont
  [ Name                                   ]    ← inset field, focused; Return creates
  Color                                         ← captionFont semibold, textSecondary
  ● ● ● ● ● ● ● ● ● ● ● ● ● ● ●  ◐               ← LabelColorPicker
  Symbol
  ┌ SymbolPicker (profileSymbolChoices), 160 pt, scrolls ┐
  ( Cancel )                          [ Create ]   ← Create = default action, disabled while the name is blank
```

**Today** (F1): idle, with 2+ profiles, `ProfileBadge(profile: profiles.activeProfile, size: .small)` sits next to
the date in the header. If the profile offers no labels, the start card shows "No labels yet." (caption,
`textTertiary`) and a Quiet "Add labels" button. Active, with 2+ profiles, the header carries a `Menu` labelled
with `ProfileBadge(profile: engine.activeSessionProfile)`: "Switch to “Work”" (only when the session's profile
isn't current) and a "Move to" submenu. A move that copies labels asks first: "Move to Personal?" / "Labels and
tags not in Personal are copied." / "Move".
```
  Today                                 ⌂ Personal   Wednesday, Oct 7
```

**Session detail** (F1): with 2+ profiles a header row `ProfilePicker(selection:title: "Profile")`; the binding's
setter confirms as above, then moves.

**End-of-session sheet, menu bar, overlay** (F1/F2): with 2+ profiles a `.small` `ProfileBadge` in the header
(sheet), in the status row while active or left of Start while idle (menu bar). The overlay header shows a 6 pt
dot in the profile color and the name in `captionFont` `textTertiary`, truncating.

**Settings ▸ Profiles** (F3, `SettingsProfilesTab`):
```
  Quick start in **Current profile ⌄**        ← ProfileValuePicker(nilTitle: "Current profile")
  Used by the menu bar and the overlay.       ← SettingsFootnote
  ┌ list (230) ─────────────┬ editor ──────────────────────────────────────────────────┐
  │ Profiles                │ Name [ Work                  ]                           │
  │  ✓ ▣ Work      12       │ Color  ● ● ● ● …   (LabelColorPicker)                    │
  │    ▣ Personal   3       │ Symbol [grid 240 pt] (SymbolPicker, profileSymbolChoices)│
  │ Archived                │ Default label **Deep work ⌄**  (LabelValuePicker,        │
  │    ▣ Old job            │   profileID: profile.uuid)  “None” uses your first label.│
  │ [+]   Drag to reorder   │ 12 sessions                                              │
  │                         │ ( Switch to ) ( Archive ) {! Delete… }                   │
  └─────────────────────────┴──────────────────────────────────────────────────────────┘
```
- List rows: checkmark slot (current profile), `ProfileSymbolTile`, name, session count trailing (`captionFont`,
  `textTertiary`, tabular). [+] presents `ProfileCreateSheet(selectsNewProfile: false)`.
- Archive and Delete are disabled for the last active profile (help "Keep at least one profile").
- Delete sheet: "Delete “Personal”?" / "12 sessions use it." / Picker "Move sessions to" (other non-archived
  profiles, then "Delete sessions") / ( Cancel ) {!Delete}. "Delete sessions" with sessions asks again:
  "Delete 12 sessions?" / "This can’t be undone." / "Delete Sessions". A safety backup (`backupNow(reason: .manual)`)
  is written first; if it fails nothing is deleted and the error shows under the picker. A running session in that
  profile shows "Stop the session first." there instead (`danger`, `captionFont`), before any backup. Archiving a
  profile whose session is running shows the same refusal under the action row.
- Color and symbol edits save (and bump `modifiedAt`) only from the user's own edits, never when a synced change
  arrives.

**Settings ▸ Labels & Tags** (F3): lists show the items offered in the current profile; global rows end with the
`globe` icon. The editor adds `ValuePicker("Available in", …)` with "All profiles" / "Work only". Making an item
local that other profiles use asks: "Make “Meetings” Work only?" / "Other profiles keep their own copy." /
"Make Local".
```
  Available in **All profiles ⌄**
```
- Usage counts (list rows, the editor's Usage footnote, the delete sheet) count only the current profile's
  sessions, segments and learning points.
- With 2+ profiles, a global item's action row ends with the footnote "Changes it in all profiles." (archive,
  merge, delete); the delete sheet repeats it, and the merge / tag-delete dialogs say "in all profiles".
- A global tag's parent label picker offers only global labels (`globalOnly`). Making a tag global drops a local
  parent label.

**Settings ▸ Data** (F3): with 2+ profiles (archived ones count) the Export section ends with the footnote
"Includes all profiles."

**Stats** (F3): with 2+ profiles, a native menu `Picker` (labels hidden) in the header: "Work" / "All profiles".
In All-profiles mode a "By profile" chart (horizontal bars in profile colors, profile names as the axis labels,
so color is never the only signal).

### 16.5 Copy (exact strings)

Follows §12.0. Menu items and buttons in title case where they are commands (macOS menus), sentence case
elsewhere.

| Where | String |
|---|---|
| Switcher help / a11y | "Switch profile" / label "Profile", value = name |
| Switcher list | "New Profile…" · "Manage Profiles…" · container "Profiles" · row hints "Shows the profile list." / "Hides the profile list." |
| Create sheet | "New profile" · prompt "Name" · "Color" · "Symbol" · "Cancel" · "Create" |
| Badge, no profile | "No profile" |
| Picker option suffixes | "Name (archived)" · "Name (Personal)" |
| Tag popover sections | "Any label" · "Other labels" · "Other profiles" |
| Settings tab | "Profiles" |
| Quick start | "Quick start in" · "Current profile" · footnote "Used by the menu bar and the overlay." |
| Scope | "Available in" · "All profiles" · "X only" · globe help "All profiles" |
| Scope confirm | "Make “X” Y only?" · "Other profiles keep their own copy." · "Make Local" |
| Move | "Move to" · "Move to Y?" · "Labels and tags not in Y are copied." · "Move" · "Switch to “Y”" |
| Shortcut | menu "Next Profile" · Shortcuts row "Switch to Next Profile" (no default) |
| Today, empty profile | "No labels yet." · "Add labels" |
| Results / disabled help | "Keep at least one profile." (help without the period) · "Stop the session first." · "Choose another profile." |
| Delete | "Delete “X”?" · "N sessions use it." · "Move sessions to" · "Delete sessions" · "Delete N sessions?" · "This can’t be undone." · "Delete Sessions" |
| Stats | "All profiles" · "By profile" |
| Global items (2+ profiles) | "Changes it in all profiles." · "Moves its sessions in all profiles to “X” and deletes it." · "Moves its uses in all profiles to “X” and deletes it." · "Sessions in all profiles are kept, but this can’t be undone." |
| Data ▸ Export (2+ profiles) | "Includes all profiles." |

### 16.6 Do / Don't

- Do show profile context only with 2+ profiles (badges, menus, Stats picker); the switcher is always there.
- Do pass `profileID:` explicitly to every label/tag picker; don't read `ProfileStore` inside popovers.
- Do use `ProfileBadge` for a profile; don't put a profile in a chip or reuse `LabelBadge`.
- Do resolve held profiles with `ModelLiveness.live(_:)` before reading them; pass UUIDs and value snapshots
  into popovers and menus, never models.
- Don't filter `@Query` by profile with `#Predicate`; filter in memory with `ProfileScope` (ARCHITECTURE §12).

---

## 17. Round 4: inline profile list, smaller edit badges, overlay grid

Summary (details in the sections named; where they and an earlier rule disagree, these win):
- **Sidebar profile list** (§16.4): the switcher row expands an inline list above itself (no popover), inside the
  sidebar's bottom inset; the footer never moves. 180 ms, none under Reduce Motion. The list's height is capped
  by `ProfileSwitcher.menuHeightLimit(sidebarHeight:)`; only profile rows scroll, the actions always show.
  "New Profile…" opens the sheet right away.
- **Edit badges** (§8.1): (−) is 14 pt with a 22 pt hit area on the **top-trailing** corner, placed only via
  `editRemoveBadge(_:accessibilityLabel:action:)`; the new `EditResizeHandle` (4 × 14 capsule, 20 × 24 hit
  area) sits on the trailing edge; (+) is 24 pt.
- **Overlay grid** (§10.6, §10.6.1): 6 columns, rows of intrinsic height, row 0 = the header row. Elements are
  placed freely and snap to cells; dropping on occupied columns pushes those elements into a new row below;
  widths resize in column steps (never pushing). Compact uses the same placements.

### 17.1 Do / Don't

- Do apply `.wiggle` first, then `editRemoveBadge`, then the resize handle overlay, then the gesture, so the
  chrome doesn't rotate and stays above the hit layer.
- Do draw the drag's floating copy and ghost in an overlay on the whole grid; don't offset the original element.
- Don't put gestures, `GeometryReader`s or preferences on the live overlay; editing only.
- Don't clip grid cells (badges overhang them by 4 pt); let elements truncate instead (no `fixedSize()`).
- Don't give the profile list a fixed height from data, a shadow or `elevatedSurface`; it is part of the sidebar.

### 17.2 Copy (exact strings)

| Where | String |
|---|---|
| Grid element actions (context menu and VoiceOver) | "Move Left" · "Move Right" · "Move Up" · "Move Down" · "Wider" · "Narrower" · "Remove" |
| Remove badge | help "Remove" · a11y "Remove *Element*" |
| Resize handle | help "Resize" |
| Element value (VoiceOver) | "Row N, columns A–B" · "Row N, column A" (1-based; the header row is row 1) |
| Editor footnote | "Drag to move; drag the right edge to resize." |
| (+) disabled | help "All elements shown" |
| Switcher list | "Profiles" (container) · "New Profile…" · "Manage Profiles…" · hints "Shows the profile list." / "Hides the profile list." |
