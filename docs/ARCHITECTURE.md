# Worklog — Architecture (docs/ARCHITECTURE.md)

> How Worklog is built: files, models, services and the rules between them. Sections 1–10 are the original design; later rounds (§11–§14) add to it and say where they replace it. When code and this document disagree, the code wins and this document should be fixed. Helper types use their folder's prefix (§1.3) or are `private`/`fileprivate`.

---

## 0. Overview

**Worklog** is a native macOS 14+ work-session tracker. You start a session with a label, pause and resume it, split it into segments when your focus changes, and take timestamped notes. At the end you title it and record learnings. You can later browse, search and edit history, follow how your learnings evolve per tag, and view stats. Quick access comes from a `MenuBarExtra` window panel and an optional floating, non-activating `NSPanel` overlay.

Stack: Swift 5 language mode, SwiftUI, Observation, SwiftData + CloudKit (private DB) with local fallback, AuthenticationServices, Swift Charts and ImageIO. The Xcode project (`Worklog.xcodeproj`) is committed. There are no third-party dependencies.

**Identity vs. sync:**
- iCloud sync uses the Mac's signed-in iCloud account through the CloudKit private database. It works whether or not the user signs in with Apple.
- Sign in with Apple is the app's account and identity gate. It stores the Apple user ID in the Keychain and checks the credential state at launch.
- "Continue without signing in" (guest mode) keeps everything working, both local storage and iCloud.
- Signing out never deletes data.

**Identifiers** (final; set in `scripts/generate_xcodeproj.py`, the entitlements files and `AppConstants`):
- bundle id `app.dabora.worktracker` (Release); Debug builds run as `app.dabora.worktracker.debug`, with their own container, store and defaults
- CloudKit container `iCloud.app.dabora.worktracker`
- Release signs with `WorklogRelease.entitlements` (CloudKit **Production**); Debug with `Worklog.entitlements` (Development). See §14.1.

---

## 1. Files and ownership

Owners:
- **PL** = Planner
- **CORE** = Core programmer (phase 2)
- **DES** = Designer (phase 2)
- **A** = Feature A: live session, menu bar, overlay (phase 3)
- **B** = Feature B: history and detail (phase 3)
- **C** = Feature C: learning, stats, settings, welcome (phase 3)

### 1.1 Tree

```
/scripts/generate_xcodeproj.py                      CORE  (writes Worklog.xcodeproj; project settings live here)
/Worklog.xcodeproj                                  CORE  (committed, generated)
/README.md                                          CORE  (setup, signing, data locations, release checklist)
/.gitignore                                         CORE  (Worklog.xcodeproj/, DerivedData/, xcuserdata/, .DS_Store, build/)
/docs/ARCHITECTURE.md                               PL
/docs/DESIGN.md                                     DES

/Worklog/Resources/Info.plist                       CORE  (versions from build settings: $(MARKETING_VERSION), $(CURRENT_PROJECT_VERSION))
/Worklog/Resources/Worklog.entitlements             CORE  (full capabilities; Debug → CloudKit Development)
/Worklog/Resources/WorklogRelease.entitlements      CORE  (same + CloudKit Production environment; Release)
/Worklog/Resources/WorklogLocal.entitlements        CORE  (sandbox + files + network only, for running without a team)
/Worklog/Resources/Assets.xcassets/Contents.json                      CORE
/Worklog/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json   CORE
/Worklog/Resources/Assets.xcassets/AccentColor.colorset/Contents.json CORE

/Worklog/App/WorklogApp.swift                       CORE  (@main, scenes)
/Worklog/App/AppDelegate.swift                      CORE
/Worklog/App/AppServices.swift                      CORE  (service container + View.withAppServices)
/Worklog/App/AppConstants.swift                     CORE  (AppConstants, WindowID)
/Worklog/App/RootView.swift                         CORE
/Worklog/App/SidebarItem.swift                      CORE
/Worklog/App/WindowRouter.swift                     CORE
/Worklog/App/WorklogCommands.swift                  CORE

/Worklog/Models/PauseInterval.swift                 CORE
/Worklog/Models/WorkSession.swift                   CORE
/Worklog/Models/Segment.swift                       CORE
/Worklog/Models/Note.swift                          CORE
/Worklog/Models/Attachment.swift                    CORE
/Worklog/Models/WorkLabel.swift                     CORE
/Worklog/Models/WorkTag.swift                       CORE
/Worklog/Models/LearningPoint.swift                 CORE
/Worklog/Models/WorklogSchema.swift                 CORE

/Worklog/Persistence/PersistenceController.swift    CORE  (StoreMode, Entitlements helper)
/Worklog/Persistence/SeedData.swift                 CORE
/Worklog/Persistence/PreviewData.swift              CORE

/Worklog/Services/SessionEngine.swift               CORE  (SessionEngine, AutoPauseReason, SessionTakeaway: state, lifecycle, controls)
/Worklog/Services/SessionEngine+Review.swift        CORE  (completeReview, two-phase discard of the reviewed session)
/Worklog/Services/SessionEngine+Takeaway.swift      CORE  (takeaway lookup, "Done", next-session-only lifecycle)
/Worklog/Services/SessionEngine+Ownership.swift     CORE  (which Mac controls a running session; handoff end)
/Worklog/Services/SessionEngine+SystemEvents.swift  CORE  (sleep/wake/activation/store notifications)
/Worklog/Services/LiveSessionRules.swift            A     (LiveDayMath, LiveStartChoice, LiveLongSessionRule, LiveProfileMove: pure rules)
/Worklog/Services/SafeSave.swift                    CORE  (save-or-rollback + user-visible error, `.worklogSaveFailed`)
/Worklog/Services/ProfileStore.swift                CORE  (ProfileScope, ProfileStore; §12.5)
/Worklog/Services/ProfileOps.swift                  CORE  (profile create/archive/delete/move, effective profile; §12.6)
/Worklog/Services/SyncMonitor.swift                 CORE  (CloudKit event/account monitor, first-import flag)
/Worklog/Services/SingleInstanceGuard.swift         CORE  (one running instance; relaunch hand-off)
/Worklog/Services/SessionEditor.swift               CORE  (SessionEditor, SessionEditError)
/Worklog/Services/TaxonomyOps.swift                 CORE
/Worklog/Services/AuthService.swift                 CORE  (AuthState, AuthService)
/Worklog/Services/KeychainStore.swift               CORE
/Worklog/Services/BackupService.swift               CORE  (BackupService, BackupFile, BackupReason)
/Worklog/Services/ExportService.swift               CORE  (ExportService, ImportMode, ImportSummary, DataTransferError, Notification.Name: export, delete-all)
/Worklog/Services/ExportService+Import.swift        CORE  (decodeArchive, importArchive merge/replace, pure import rules)
/Worklog/Services/ExportService+Mapping.swift       CORE  (model → DTO mapping, CSV helpers)
/Worklog/Services/ExportDTOs.swift                  CORE
/Worklog/Services/SearchService.swift               CORE  (SearchService, SearchSnippet)
/Worklog/Services/AttachmentImporter.swift          CORE  (AttachmentImporter, ImportedImage, AttachmentImportError)
/Worklog/Services/AppSettings.swift                 CORE  (AppSettings, BackupInterval)
/Worklog/Services/OverlayPanelController.swift      CORE  (OverlayPanelController, OverlayPanel)
/Worklog/Services/OverlayLayout.swift               CORE  (OverlayElement; round 2, §11.1. Grid model: OverlayPlacement, OverlayGridLayout, OverlayGridGeometry…; round 4, §13.2)
/Worklog/Services/ShortcutStore.swift               CORE  (ShortcutStore, ShortcutAction, ShortcutGroup, StoredShortcut, ShortcutValidation; round 2, §11.3)

/Worklog/Utilities/Formatting.swift                 CORE  (TimeInterval/Date/DateInterval/String extensions)
/Worklog/Utilities/Log.swift                        CORE
/Worklog/Utilities/ModelLiveness.swift              CORE  (isLive/live guards for possibly-deleted models)

/Worklog/DesignSystem/Theme.swift                   DES   (Theme struct + Theme.make + fallback)
/Worklog/DesignSystem/ThemeID.swift                 DES   (ThemeID, AppearanceMode, AccentChoice)
/Worklog/DesignSystem/ThemeManager.swift            DES
/Worklog/DesignSystem/ThemeEnvironment.swift        DES   (EnvironmentValues.theme, View.worklogThemed, SurfaceLevel, themedBackground, cardStyle)
/Worklog/DesignSystem/Themes/PaperTheme.swift       DES
/Worklog/DesignSystem/Themes/GraphiteTheme.swift    DES
/Worklog/DesignSystem/Themes/MeadowTheme.swift      DES
/Worklog/DesignSystem/Color+Hex.swift               DES   (Color(hex:), hexString, LabelPalette)
/Worklog/DesignSystem/Model+Color.swift             DES   (WorkLabel.color, WorkTag.color)
/Worklog/DesignSystem/Components/Card.swift         DES
/Worklog/DesignSystem/Components/SectionHeader.swift DES
/Worklog/DesignSystem/Components/LabelBadge.swift   DES   (+ BadgeSize)
/Worklog/DesignSystem/Components/TagChip.swift      DES
/Worklog/DesignSystem/Components/ColorDot.swift     DES
/Worklog/DesignSystem/Components/TimerText.swift    DES   (+ TimerTextStyle)
/Worklog/DesignSystem/Components/ButtonStyles.swift DES
/Worklog/DesignSystem/Components/EmptyStateView.swift DES
/Worklog/DesignSystem/Components/SearchField.swift  DES
/Worklog/DesignSystem/Components/StatTile.swift     DES
/Worklog/DesignSystem/Components/FlowLayout.swift   DES
/Worklog/DesignSystem/Components/InlineBanner.swift DES   (+ BannerStyle)
/Worklog/DesignSystem/Components/ThemePreviewSwatch.swift DES

/Worklog/Shared/LabelPicker.swift                   DES
/Worklog/Shared/TagPicker.swift                     DES
/Worklog/Shared/TagChipsRow.swift                   DES
/Worklog/Shared/NoteRow.swift                       DES
/Worklog/Shared/LabelColorPicker.swift              DES
/Worklog/Shared/SymbolPicker.swift                  DES

/Worklog/Features/LiveSession/LiveSessionView.swift      A  (public: LiveSessionView)
/Worklog/Features/LiveSession/EndSessionSheet.swift      A  (public: EndSessionSheet)
/Worklog/Features/LiveSession/*.swift (any more)         A
/Worklog/Features/MenuBar/MenuBarPanelView.swift         A  (public: MenuBarPanelView)
/Worklog/Features/MenuBar/MenuBarLabelView.swift         A  (public: MenuBarLabelView)
/Worklog/Features/MenuBar/*.swift                        A
/Worklog/Features/Overlay/OverlayView.swift              A  (public: OverlayView)
/Worklog/Features/Overlay/OverlayGridViews.swift         A  (round 4: OverlayGridRowLayout, cell/frame keys, render helpers)
/Worklog/Features/Overlay/*.swift                        A

/Worklog/Features/History/HistoryView.swift              B  (public: HistoryView)
/Worklog/Features/History/*.swift                        B  (e.g. HistorySort, HistoryRowView)
/Worklog/Features/SessionDetail/SessionDetailView.swift  B  (public: SessionDetailView)
/Worklog/Features/SessionDetail/LearningsEditor.swift    B  (public: LearningsEditor, LearningsEditorStyle) — used by A
/Worklog/Features/SessionDetail/*.swift                  B

/Worklog/Features/Learning/LearningView.swift            C  (public: LearningView)
/Worklog/Features/Learning/*.swift                       C
/Worklog/Features/Stats/StatsView.swift                  C  (public: StatsView)
/Worklog/Features/Stats/*.swift                          C  (e.g. StatsCalculator)
/Worklog/Features/Settings/SettingsView.swift            C  (public: SettingsView)
/Worklog/Features/Settings/WelcomeView.swift             C  (public: WelcomeView)
/Worklog/Features/Settings/*.swift                       C

/WorklogTests/SessionMathTests.swift                CORE
/WorklogTests/SessionEditorTests.swift              CORE
/WorklogTests/ExportRoundTripTests.swift            CORE
/WorklogTests/OverlayLayoutTests.swift              CORE  (round 2)
/WorklogTests/ShortcutStoreTests.swift              CORE  (round 2)
/WorklogTests/OverlayGridLayoutTests.swift          CORE  (round 4, §13.6)
```

### 1.2 Cross-agent dependencies

Each item below is defined by the first agent and consumed by the second.

| Provider → Consumer | What |
|---|---|
| CORE → everyone | Models, services, AppSettings, WindowRouter, formatting helpers, AttachmentImporter, SessionEditor, TaxonomyOps, SearchService |
| DES → everyone | Theme, components, Shared pickers, `Color(hex:)` |
| DES → CORE | `ThemeManager`, `View.worklogThemed(_:)` (used in `withAppServices`) |
| A → CORE | `LiveSessionView()`, `EndSessionSheet(session:)`, `MenuBarPanelView()`, `MenuBarLabelView()`, `OverlayView()` |
| B → CORE | `HistoryView()` |
| B → A | `LearningsEditor(session:style:)` |
| C → CORE | `LearningView()`, `StatsView()`, `SettingsView()`, `WelcomeView()` |

### 1.3 Naming rules (avoid collisions)

- Never name a type `Label`, `Tag`, `Section`, `Group`, `Table`, `Text`, `Image`, `Color`, `Timer`, `Settings`, `Menu` or `Window`. These names clash with SwiftUI or Foundation.
- Helper types that are not listed in this doc must be `private` or `fileprivate`, or carry the owner prefix:
  - **A:** `Live…`, `EndSession…`, `MenuBar…`, `Overlay…`
  - **B:** `History…`, `Detail…`, `Learnings…`
  - **C:** `LearningPage…`, `Stats…`, `Settings…`, `Welcome…`
  - **DES:** anything inside `DesignSystem/` or `Shared/`
  - **CORE:** anything in its own files
- No agent adds non-private extensions on shared types (models, Date, TimeInterval, String, Color, View) outside the files that own them. Use `private extension` in your own file.

---

## 2. Data model (SwiftData + CloudKit)

**CloudKit rules (all satisfied below):**
- Every stored property has a default value or is optional.
- Every relationship is optional and has an inverse. The inverse is declared with `@Relationship(inverse:)` on **exactly one** side.
- No `.unique`, no `.deny`, no ordered relationships. Ordering uses `sortIndex` or timestamps.
- Codable pause intervals are stored as JSON `Data`.
- Images use `.externalStorage` and sync as CKAssets.

**Using models:**
- `context.insert(obj)` **before** you set relationships on a new object.
- To-many arrays are optional. Use the non-optional `tagList` accessors and the `sorted…` helpers.
- Every model has `uuid: UUID` as a stable cross-device id. Do not declare `id`; use `persistentModelID` and the synthesized `Identifiable`.
- **Schema evolution:** additive only, and every new property needs a default. In production, CloudKit schemas can't drop or rename fields.

**Invariants:**
- At most one session has `endedAt == nil`. That session is the active one.
- A session always has at least one segment.
- Segments, sorted by `sortIndex`, are contiguous:
  - `seg[0].startedAt == session.startedAt`
  - `seg[i].endedAt == seg[i+1].startedAt`
  - the last segment's `endedAt == session.endedAt`
- Only the active session's last segment has `endedAt == nil`.
- A session is paused exactly when it is active **and** its last `PauseInterval` has `end == nil`.

**Semantics:**
- `WorkSession.label` is the primary label.
- `Segment.label` is that segment's focus label. `effectiveLabel` falls back to the session label.
- `WorkSession.tags` apply to the whole session. `Segment.tags` apply to that segment only.
- Time per label is computed from segments (`effectiveLabel`).
- Time per tag counts a segment's active time if the tag is in `segment.tags ∪ session.tags`.
- `WorkTag.label` makes the tag a sub-label of that label (shown first in pickers). `nil` means a global tag.

### 2.1 `Worklog/Models/PauseInterval.swift`
```swift
import Foundation

/// A pause inside a session. `end == nil` ⇒ currently paused (only valid on the active session's last interval).
struct PauseInterval: Codable, Hashable {
    var start: Date
    var end: Date?

    init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    var isOpen: Bool { end == nil }

    /// Seconds of this pause inside `window`; an open pause is treated as ending at `now`.
    func overlap(with window: DateInterval, now: Date) -> TimeInterval {
        let s = max(start, window.start)
        let e = min(end ?? now, window.end)
        return max(0, e.timeIntervalSince(s))
    }
}

extension Array where Element == PauseInterval {
    func totalOverlap(with window: DateInterval, now: Date) -> TimeInterval {
        reduce(0) { $0 + $1.overlap(with: window, now: now) }
    }
}
```

### 2.2 `Worklog/Models/WorkSession.swift`
```swift
import Foundation
import SwiftData

@Model
final class WorkSession {
    var uuid: UUID = UUID()
    var title: String = ""
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    /// JSON-encoded `[PauseInterval]`. Use `pauseIntervals`.
    var pauseIntervalsData: Data? = nil
    /// Cached `activeDuration` (seconds) for sorting. Refresh with `recomputeStoredDuration()` after any time edit/stop.
    var storedActiveDuration: Double = 0
    /// Free-text "what I learned".
    var learningText: String = ""
    /// Optional short user-written takeaway for the next session's overlay.
    var overlaySummary: String = ""
    /// Show this session's takeaway in overlay/menu bar of the next session.
    var showInOverlay: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.sessions)
    var label: WorkLabel?
    @Relationship(deleteRule: .nullify, inverse: \WorkTag.sessions)
    var tags: [WorkTag]? = []
    @Relationship(deleteRule: .cascade, inverse: \Segment.session)
    var segments: [Segment]? = []
    @Relationship(deleteRule: .cascade, inverse: \Note.session)
    var notes: [Note]? = []
    @Relationship(deleteRule: .cascade, inverse: \Attachment.session)
    var attachments: [Attachment]? = []
    @Relationship(deleteRule: .cascade, inverse: \LearningPoint.session)
    var learningPoints: [LearningPoint]? = []

    init(startedAt: Date = .now, title: String = "", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.startedAt = startedAt
        self.title = title
        self.createdAt = .now
        self.modifiedAt = .now
    }
}

extension WorkSession {
    var pauseIntervals: [PauseInterval] {
        get {
            guard let data = pauseIntervalsData else { return [] }
            return (try? JSONDecoder().decode([PauseInterval].self, from: data)) ?? []
        }
        set { pauseIntervalsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue)) }
    }

    var isActive: Bool { endedAt == nil }
    var isPaused: Bool {
        guard isActive, let last = pauseIntervals.last else { return false }
        return last.end == nil
    }
    var displayTitle: String { title.isBlank ? "Untitled session" : title.trimmed }

    func wallDuration(at now: Date = .now) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
    func pausedDuration(at now: Date = .now) -> TimeInterval {
        pauseIntervals.totalOverlap(with: DateInterval(safeStart: startedAt, end: endedAt ?? now), now: now)
    }
    /// Wall time minus pauses.
    func activeDuration(at now: Date = .now) -> TimeInterval {
        max(0, wallDuration(at: now) - pausedDuration(at: now))
    }
    /// Active time clipped to `window` (use for per-day stats; handles midnight crossing).
    func activeDuration(in window: DateInterval, now: Date = .now) -> TimeInterval {
        let own = DateInterval(safeStart: startedAt, end: endedAt ?? now)
        guard let clip = own.intersection(with: window) else { return 0 }
        return max(0, clip.duration - pauseIntervals.totalOverlap(with: clip, now: now))
    }
    func recomputeStoredDuration(now: Date = .now) { storedActiveDuration = activeDuration(at: now) }
    func touch() { modifiedAt = .now }

    var sortedSegments: [Segment] {
        (segments ?? []).sorted { ($0.sortIndex, $0.startedAt) < ($1.sortIndex, $1.startedAt) }
    }
    /// The open segment of an active session.
    var currentSegment: Segment? { sortedSegments.last(where: { $0.endedAt == nil }) }
    /// Segment whose [start, end) contains `date`; falls back to first/last.
    func segment(containing date: Date) -> Segment? {
        let segs = sortedSegments
        if let hit = segs.first(where: { $0.startedAt <= date && date < ($0.endedAt ?? .distantFuture) }) { return hit }
        return date < startedAt ? segs.first : segs.last
    }
    var sortedNotes: [Note] { (notes ?? []).sorted { $0.createdAt < $1.createdAt } }
    var sortedAttachments: [Attachment] { (attachments ?? []).sorted { $0.createdAt < $1.createdAt } }
    var sortedLearningPoints: [LearningPoint] {
        (learningPoints ?? []).sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    /// Session tags ∪ segment tags, unique by uuid, sorted by name.
    var allTags: [WorkTag] {
        var seen = Set<UUID>(); var result: [WorkTag] = []
        for t in tagList + (segments ?? []).flatMap({ $0.tagList }) where seen.insert(t.uuid).inserted { result.append(t) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// overlaySummary if non-blank, else learningText if non-blank, else nil.
    var takeawayText: String? {
        if !overlaySummary.isBlank { return overlaySummary.trimmed }
        if !learningText.isBlank { return learningText.trimmed }
        return nil
    }
    /// Latest of startedAt, segment starts, note times, pause ends (for "forgot to stop").
    var lastActivityDate: Date {
        var d = startedAt
        for s in segments ?? [] { d = max(d, s.startedAt) }
        for n in notes ?? [] { d = max(d, n.createdAt) }
        for p in pauseIntervals { d = max(d, p.end ?? p.start) }
        return d
    }
}
```

### 2.3 `Worklog/Models/Segment.swift`
```swift
import Foundation
import SwiftData

@Model
final class Segment {
    var uuid: UUID = UUID()
    var startedAt: Date = Date()
    /// nil only for the open segment of the active session.
    var endedAt: Date? = nil
    var sortIndex: Int = 0
    /// Short "what I'm focusing on" text.
    var focus: String = ""

    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.segments)
    var label: WorkLabel?
    @Relationship(deleteRule: .nullify, inverse: \WorkTag.segments)
    var tags: [WorkTag]? = []
    var session: WorkSession?
    @Relationship(deleteRule: .nullify, inverse: \Note.segment)
    var notes: [Note]? = []

    init(startedAt: Date = .now, endedAt: Date? = nil, sortIndex: Int = 0, focus: String = "", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sortIndex = sortIndex
        self.focus = focus
    }
}

extension Segment {
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    var effectiveLabel: WorkLabel? { label ?? session?.label }
    var displayFocus: String { focus.isBlank ? (effectiveLabel?.name ?? "Segment") : focus.trimmed }
    func interval(now: Date = .now) -> DateInterval {
        DateInterval(safeStart: startedAt, end: endedAt ?? session?.endedAt ?? now)
    }
    func activeDuration(at now: Date = .now) -> TimeInterval {
        let iv = interval(now: now)
        return max(0, iv.duration - (session?.pauseIntervals.totalOverlap(with: iv, now: now) ?? 0))
    }
    func activeDuration(in window: DateInterval, now: Date = .now) -> TimeInterval {
        guard let clip = interval(now: now).intersection(with: window) else { return 0 }
        return max(0, clip.duration - (session?.pauseIntervals.totalOverlap(with: clip, now: now) ?? 0))
    }
    var sortedNotes: [Note] { (notes ?? []).sorted { $0.createdAt < $1.createdAt } }
}
```

### 2.4 `Worklog/Models/Note.swift`
```swift
import Foundation
import SwiftData

@Model
final class Note {
    var uuid: UUID = UUID()
    /// The displayed timestamp (when the note was taken / is about).
    var createdAt: Date = Date()
    var editedAt: Date? = nil
    var text: String = ""
    var session: WorkSession?
    var segment: Segment?

    init(text: String, createdAt: Date = .now, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.text = text
        self.createdAt = createdAt
    }
}
```

### 2.5 `Worklog/Models/Attachment.swift`
```swift
import Foundation
import SwiftData
import AppKit

@Model
final class Attachment {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var filename: String = ""
    var caption: String = ""
    /// UTI of `data`: "public.jpeg" or "public.png".
    var uti: String = "public.jpeg"
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    @Attribute(.externalStorage) var data: Data? = nil
    @Attribute(.externalStorage) var thumbnailData: Data? = nil
    var session: WorkSession?

    init(filename: String = "", data: Data? = nil, thumbnailData: Data? = nil,
         uti: String = "public.jpeg", pixelWidth: Int = 0, pixelHeight: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.filename = filename
        self.data = data
        self.thumbnailData = thumbnailData
        self.uti = uti
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

extension Attachment {
    var image: NSImage? { data.flatMap { NSImage(data: $0) } }
    var thumbnailImage: NSImage? { (thumbnailData ?? data).flatMap { NSImage(data: $0) } }
    var fileExtension: String { uti == "public.png" ? "png" : "jpg" }
}
```

### 2.6 `Worklog/Models/WorkLabel.swift`
```swift
import Foundation
import SwiftData

@Model
final class WorkLabel {
    var uuid: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#5B8DEF"
    var symbolName: String = "circle.fill"
    var sortIndex: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()

    var sessions: [WorkSession]? = []
    var segments: [Segment]? = []
    /// Sub-labels (tags scoped to this label).
    var tags: [WorkTag]? = []

    init(name: String, colorHex: String = "#5B8DEF", symbolName: String = "circle.fill",
         sortIndex: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
    }
}

extension WorkLabel {
    var usageCount: Int { (sessions?.count ?? 0) + (segments?.count ?? 0) }
}
```

### 2.7 `Worklog/Models/WorkTag.swift`
```swift
import Foundation
import SwiftData

@Model
final class WorkTag {
    var uuid: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#8E8E93"
    var isArchived: Bool = false
    var createdAt: Date = Date()

    /// Optional parent label (tag acts as a sub-label). nil = global tag.
    @Relationship(deleteRule: .nullify, inverse: \WorkLabel.tags)
    var label: WorkLabel?
    var sessions: [WorkSession]? = []
    var segments: [Segment]? = []
    var learningPoints: [LearningPoint]? = []

    init(name: String, colorHex: String = "#8E8E93", uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
    }
}

extension WorkTag {
    var usageCount: Int { (sessions?.count ?? 0) + (segments?.count ?? 0) + (learningPoints?.count ?? 0) }
}
```

### 2.8 `Worklog/Models/LearningPoint.swift`
```swift
import Foundation
import SwiftData

@Model
final class LearningPoint {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var text: String = ""
    var sortIndex: Int = 0
    /// Optional self-assessed mastery 1...5; 0 = not rated. Charted on the Learning page.
    var mastery: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \WorkTag.learningPoints)
    var tags: [WorkTag]? = []
    var session: WorkSession?

    init(text: String, createdAt: Date = .now, sortIndex: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.text = text
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }
}

extension LearningPoint {
    var tagList: [WorkTag] {
        get { tags ?? [] }
        set { tags = newValue }
    }
    /// Date used on the evolution timeline: the session's start, else createdAt.
    var effectiveDate: Date { session?.startedAt ?? createdAt }
}
```

### 2.9 `Worklog/Models/WorklogSchema.swift`
```swift
import SwiftData

enum WorklogSchema {
    static let models: [any PersistentModel.Type] = [
        WorkSession.self, Segment.self, Note.self, Attachment.self,
        WorkLabel.self, WorkTag.self, LearningPoint.self
    ]
    static var schema: Schema { Schema(models) }
}
```

---

## 3. Services (CORE): exact public interfaces

All services are `@MainActor`. They are injected with `.environment(obj)` and read with `@Environment(Type.self)`. Every service is `@Observable final class` so it can be injected, even when it holds little state. All SwiftData work uses `container.mainContext`.

### 3.1 `AppConstants.swift`
```swift
enum AppConstants {
    static let appName = "Worklog"
    static let bundleID = "app.dabora.worktracker"               // log subsystem / fallback only
    static let cloudKitContainerID = "iCloud.app.dabora.worktracker" // fallback; the entitlements win
    static let backupFolderName = "Backups"
    static let recoveredFolderName = "Recovered"
    static var rootDirectoryOverride: URL?   // unit tests only (temporary folder); nil in the app
    static var applicationSupportURL: URL   // URL.applicationSupportDirectory/Worklog (created if missing)
    static var backupsURL: URL               // applicationSupportURL/Backups (created if missing)
    static var storeURL: URL                 // applicationSupportURL/Worklog.store
    static var recoveredURL: URL             // applicationSupportURL/Recovered (damaged stores, PreOpen snapshots, unsaved data)
    static var pendingRestoreURL: URL        // applicationSupportURL/pending-restore.json
    static var restoreInProgressURL: URL     // applicationSupportURL/restore-in-progress.json (M1 breadcrumb)
    static var storeFileURLs: [URL]          // store, -wal, -shm, .Worklog_SUPPORT
    static func fileTimestamp(_ date: Date = .now) -> String   // "2026-10-07T14-03-22Z" (UTC)
    static var appVersion: String; static var buildNumber: String; static var buildConfiguration: String
}
enum WindowID {
    static let main = "main"
}
```

### 3.2 `PersistenceController`

> **Superseded in part (round 4a):** the opening order below is the original one. The shipped order (PreOpen snapshot, pending "Move to iCloud" marker, CloudKit environment guard, newer-store detection) is documented on `PersistenceController.init` and in §14.2.

```swift
enum StoreMode: Equatable {
    case cloudKit
    case localOnly(reason: String)   // e.g. "Not signed in to iCloud", "iCloud sync disabled", "CloudKit unavailable: <err>"
    case inMemory(reason: String)    // store failed to open; data NOT persisted — UI must warn + offer restore
}

@MainActor @Observable
final class PersistenceController {
    let container: ModelContainer
    let storeMode: StoreMode
    var mainContext: ModelContext { container.mainContext }
    var isSyncingWithICloud: Bool { storeMode == .cloudKit }

    /// Order of attempts:
    /// 1. If `cloudSyncEnabled && Entitlements.hasCloudKit && FileManager.default.ubiquityIdentityToken != nil`:
    ///    ModelConfiguration("Worklog", schema: WorklogSchema.schema, url: AppConstants.storeURL,
    ///                       cloudKitDatabase: .private(AppConstants.cloudKitContainerID)) → .cloudKit
    /// 2. Otherwise, or if (1) throws: same URL with `cloudKitDatabase: .none` (MUST be explicit; `.automatic` would
    ///    enable CloudKit) → .localOnly(reason)
    /// 3. If (2) throws: in-memory config (`isStoredInMemoryOnly: true, cloudKitDatabase: .none`) → .inMemory(reason).
    ///    Never delete/move the on-disk store automatically.
    /// `inMemory: true` (previews/tests) goes straight to 3 with reason "Preview".
    init(cloudSyncEnabled: Bool, inMemory: Bool = false)
}

enum Entitlements {
    /// Uses SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement.
    static func has(_ key: String) -> Bool
    static var hasCloudKit: Bool    // "com.apple.developer.icloud-services"
    static var hasSignInWithApple: Bool  // "com.apple.developer.applesignin"
}
```

### 3.3 `SeedData`
```swift
@MainActor enum SeedData {
    /// If no WorkLabel exists and UserDefaults "seed.didSeedDefaults" is false: insert default labels/tags with the
    /// FIXED uuids below, set the flag, save.
    static func seedIfNeeded(in context: ModelContext)
    /// Merge duplicate WorkLabel/WorkTag objects sharing the same uuid (CloudKit can import a second copy of the
    /// seeded rows from another Mac). The survivor is the oldest createdAt; reassign all relationships; delete the rest.
    /// Also ends extra active sessions (keeps most recent startedAt active; others: endedAt = lastActivityDate).
    static func deduplicate(in context: ModelContext)
}
```

Default labels: name, hex, SF Symbol, fixed uuid.

| # | Name | Hex | Symbol | UUID |
|---|---|---|---|---|
| 0 | Deep work | `#5B8DEF` | `brain.head.profile` | `6F1C0E10-0000-4000-8000-000000000001` |
| 1 | Meetings | `#F2994A` | `person.2.fill` | `6F1C0E10-0000-4000-8000-000000000002` |
| 2 | Admin & email | `#9B9B9B` | `tray.full.fill` | `6F1C0E10-0000-4000-8000-000000000003` |
| 3 | Learning | `#27AE60` | `book.fill` | `6F1C0E10-0000-4000-8000-000000000004` |
| 4 | Planning | `#9B51E0` | `list.bullet.clipboard` | `6F1C0E10-0000-4000-8000-000000000005` |

Default tags: global, `#8E8E93`, uuids `6F1C0E10-0000-4000-8000-0000000001xx` with xx = 01–04.

| xx | Name |
|---|---|
| 01 | coding |
| 02 | writing |
| 03 | review |
| 04 | research |

### 3.4 `SessionEngine` (`Services/SessionEngine.swift`)
```swift
enum AutoPauseReason: String, Codable { case sleep, quit }

struct SessionTakeaway: Equatable {
    var sessionUUID: UUID
    var title: String        // session.displayTitle
    var date: Date           // session.startedAt
    var text: String         // session.takeawayText!
    var labelName: String?
}

@MainActor @Observable
final class SessionEngine {
    // MARK: State (read-only for views unless noted)
    private(set) var activeSession: WorkSession?
    /// Ended session awaiting the end-of-session sheet. RootView presents `EndSessionSheet` while non-nil.
    /// Settable so `.sheet(item:)` bindings work; setting nil by dismissal must go through `completeReview()`.
    var pendingEndSession: WorkSession?
    /// Most recent ended session with showInOverlay == true and a non-nil takeawayText.
    private(set) var lastTakeaway: SessionTakeaway?
    /// Set when the engine paused automatically (sleep / quit). Persisted in UserDefaults "engine.autoPauseReason".
    private(set) var autoPauseReason: AutoPauseReason?
    /// Updated every 1 s while a session is active (Timer in .common run-loop mode). ONLY MenuBarLabelView reads it;
    /// every other view uses TimelineView(.periodic(from: .now, by: 1)).
    private(set) var tick: Date = .now
    var lastError: String?

    var isActive: Bool { activeSession != nil }
    var isPaused: Bool { activeSession?.isPaused ?? false }
    var isRunning: Bool { isActive && !isPaused }
    var currentSegment: Segment? { activeSession?.currentSegment }
    var currentLabel: WorkLabel? { currentSegment?.effectiveLabel ?? activeSession?.label }

    init(context: ModelContext, settings: AppSettings)

    // MARK: Lifecycle
    /// Fetch sessions with endedAt == nil; adopt the most recent as active (end any others at lastActivityDate);
    /// restore autoPauseReason; refreshTakeaway(); start/stop tick timer. Called once by AppServices.
    func restoreActiveSession()
    /// Re-sync with the store (after import/restore, remote CloudKit changes, app activation). Same logic as restore.
    func reconcile()
    /// Installs NSWorkspace willSleep/didWake + NSApplication.didBecomeActive observers (called by AppServices).
    func startObservingSystemEvents()
    /// On quit: if settings.pauseOnQuit && isRunning → pause(), autoPauseReason = .quit. Always saves.
    func prepareForTermination()
    func save()   // try context.save(); on error sets lastError + logs

    // MARK: Time
    /// Active (pause-excluded) seconds of the active session at `date`; 0 if none.
    func elapsed(at date: Date = .now) -> TimeInterval
    /// Active seconds of the current segment at `date`; 0 if none.
    func currentSegmentElapsed(at date: Date = .now) -> TimeInterval
    /// Active seconds today in `scope` (fetch startedAt >= today−2d, + the active session). Delegates to
    /// `LiveDayMath.totalToday` (one rule with the UI).
    func totalActiveToday(now: Date = .now, scope: ProfileScope = .allProfiles) -> TimeInterval
    /// Delegates to `LiveStartChoice.defaultLabel(in:profile:settings:)` over all labels (profile nil → current).
    func defaultLabel(for profile: WorkProfile? = nil) -> WorkLabel?

    // MARK: Controls
    /// If a session is already active, returns it unchanged. Otherwise inserts a WorkSession(startedAt: date),
    /// sets session.label = label, inserts first Segment(sortIndex 0, label, focus, tags), saves, clears
    /// autoPauseReason, starts tick. Start tags go on the FIRST SEGMENT; session.tags stays empty (round 4b).
    @discardableResult
    func start(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now) -> WorkSession
    /// No-op unless running. Appends PauseInterval(start: date).
    func pause(at date: Date = .now)
    /// No-op unless paused. Closes the open interval with end = date; clears autoPauseReason.
    func resume(at date: Date = .now)
    func togglePause()
    /// No-op (returns nil) if not active. Clamps `date` to ≥ current segment start; closes open pause at `date`
    /// and drops/clips pauses after `date`; sets segment.endedAt and session.endedAt = date;
    /// recomputeStoredDuration; save; activeSession = nil; stop tick;
    /// pendingEndSession = session if settings.showEndSessionSheet, else refreshTakeaway().
    /// Callers outside the main window MUST call `router.showMainWindow()` afterwards so the sheet is visible.
    @discardableResult
    func stop(at date: Date = .now) -> WorkSession?
    /// Deletes the active session (cascade). Callers confirm first if settings.confirmBeforeDiscard.
    func discard()
    /// Live split. Closes current segment at `date` and opens Segment(startedAt: date, sortIndex: max+1,
    /// label: label ?? currentLabel, tags: tags, focus: focus). Allowed while paused. Returns the new segment.
    @discardableResult
    func split(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now) -> Segment?
    /// Edit the current segment in place (no split). If the session has exactly one segment, session.label follows.
    func updateCurrentSegment(label: WorkLabel?, tags: [WorkTag], focus: String)
    /// Trims; ignores blank or no active session. Note(text, createdAt: date), session = active, segment = currentSegment.
    @discardableResult
    func addNote(_ text: String, at date: Date = .now) -> Note?

    // MARK: End-of-session review
    /// Save pending session (touch, recomputeStoredDuration), pendingEndSession = nil, refreshTakeaway().
    func completeReview()
    /// Delete pending session; pendingEndSession = nil.
    func discardPendingSession()
    /// Re-open pending session (only if no active session): endedAt = nil, last segment endedAt = nil,
    /// the gap [old endedAt, now] is appended as a closed PauseInterval; becomes activeSession; pendingEndSession = nil.
    func resumePendingSession()

    func refreshTakeaway()
    func clearAutoPauseReason()

    // MARK: Long-session warning (round 4b)
    /// "Keep going" per session uuid; persisted ("engine.longWarningDismissed"), cleared when the session ends.
    func isLongSessionWarningDismissed(for session: WorkSession) -> Bool
    func dismissLongSessionWarning(for session: WorkSession)
}
```

**Round 4b notes.**
- The class is split into extensions by concern: `SessionEngine+Review.swift`, `+Takeaway`, `+Ownership`, `+SystemEvents` (pure moves). Members those files share are `internal` rather than `private`; views must not use them. Everything that writes a `private(set)` property (`activeSession`, `autoPauseReason`, `takeaways`, `tick`) stays in `SessionEngine.swift`, including `resumePendingSession()`, the discard phase 2 and the sleep/wake handlers.
- `pendingEndSession`'s uuid is persisted ("engine.pendingReviewUUID"): quitting with the review open re-presents it at the next launch (`restoreActiveSession`); a deleted or still-running session is dropped.
- Sessions from older builds may carry session-level tags; they still count for every segment (Stats, filters, `allTags`).

**Sleep and wake.** On `willSleep`, if `settings.pauseOnSleep && isRunning`, the engine calls `pause(at: now)` and sets `autoPauseReason = .sleep`. On wake it does not auto-resume. Feature A shows a banner offering Resume.

**Import notification.** The engine also observes `Notification.Name.worklogDataDidImport` and calls `reconcile()` when it fires.

### 3.5 `SessionEditor`: after-the-fact edits (used by B; the engine reuses its internals)

Every mutating call:
- calls `session.touch()`
- calls `recomputeStoredDuration()`
- calls `normalize`
- runs `try? context.save()`

```swift
enum SessionEditError: LocalizedError {
    case dateOutOfRange, segmentTooShort, noAdjacentSegment, lastSegment, sessionIsActive
    var errorDescription: String? { get }   // human-readable
}

@MainActor enum SessionEditor {
    static let minimumSegmentLength: TimeInterval = 1

    /// Split `segment` at `date` (must be > start+min and < end−min, else .dateOutOfRange/.segmentTooShort).
    /// Original keeps [start, date); new segment gets [date, end) with `label` (nil → original's label),
    /// `tags` (nil → copy original's tags), `focus`. Notes with createdAt >= date move to the new segment.
    @discardableResult
    static func split(_ segment: Segment, at date: Date, label: WorkLabel?, tags: [WorkTag]?, focus: String,
                      in context: ModelContext) throws -> Segment
    /// Absorb the next segment into `segment` (next deleted, its notes reassigned). Throws .noAdjacentSegment.
    static func mergeWithNext(_ segment: Segment, in context: ModelContext) throws
    /// Delete segment; its time goes to previous (or next if first); notes reassigned. Throws .lastSegment.
    static func deleteSegment(_ segment: Segment, in context: ModelContext) throws
    /// Move the boundary between `segment` and its successor to `date` (respecting minimumSegmentLength).
    static func moveBoundary(after segment: Segment, to date: Date, in context: ModelContext) throws
    /// Ended sessions only (.sessionIsActive otherwise). start < end required. First segment start / last segment end
    /// follow; segments fully outside are clamped to min length; pauses are clipped to [start, end].
    static func setTimes(of session: WorkSession, start: Date, end: Date, in context: ModelContext) throws
    /// Set session.label; every segment whose label was the OLD primary label (or nil) is updated to the new one.
    static func setPrimaryLabel(_ label: WorkLabel?, for session: WorkSession, in context: ModelContext)
    /// Re-number sortIndex by startedAt, enforce contiguity, ensure ≥1 segment (creates one if missing).
    static func normalize(_ session: WorkSession)
    /// Throws .sessionIsActive for the active session (use engine.discard()).
    static func deleteSession(_ session: WorkSession, in context: ModelContext) throws
    /// Note in any session at `date`; segment = session.segment(containing: date).
    @discardableResult
    static func addNote(_ text: String, at date: Date, to session: WorkSession, in context: ModelContext) -> Note
    /// Sets text, editedAt = now; createdAt changed only if `date` given (segment reassigned).
    static func updateNote(_ note: Note, text: String, date: Date?, in context: ModelContext)
    static func deleteNote(_ note: Note, in context: ModelContext)
    static func deleteAttachment(_ attachment: Attachment, in context: ModelContext)
    /// sortIndex = max+1.
    @discardableResult
    static func addLearningPoint(_ text: String, tags: [WorkTag], to session: WorkSession,
                                 in context: ModelContext) -> LearningPoint
    static func deleteLearningPoint(_ point: LearningPoint, in context: ModelContext)
    /// Assign sortIndex by array order.
    static func reorderLearningPoints(_ points: [LearningPoint])
}
```

### 3.6 `TaxonomyOps`: labels and tags
```swift
@MainActor enum TaxonomyOps {
    /// sortIndex = max+1. Round 4b: a same-name ARCHIVED label offered in `profile` (nil: global ones) is unarchived
    /// and returned instead (it keeps its color and symbol).
    @discardableResult
    static func createLabel(name: String, colorHex: String, symbolName: String, profile: WorkProfile? = nil,
                            in context: ModelContext) -> WorkLabel
    /// Returns an existing non-archived tag with the same name (case-insensitive, trimmed) offered in `profile`
    /// instead of duplicating; else (round 4b) a same-name archived one, unarchived; else a new tag.
    @discardableResult
    static func createTag(name: String, colorHex: String = "#8E8E93", label: WorkLabel? = nil,
                          profile: WorkProfile? = nil, in context: ModelContext) -> WorkTag
    /// Round 4b: the archived tag/label `createTag`/`createLabel` would unarchive (for "Unarchive “x”" in pickers).
    static func archivedTag(named name: String, profile: WorkProfile?, in context: ModelContext) -> WorkTag?
    static func archivedLabel(named name: String, profile: WorkProfile?, in context: ModelContext) -> WorkLabel?
    static func unarchive(_ tag: WorkTag)          // saves
    static func unarchive(_ label: WorkLabel)      // saves
    /// Clears every profile's defaultLabelUUID pointing at `label` (e.g. it was archived). Does not save.
    static func clearDefaultLabel(_ label: WorkLabel, in context: ModelContext)
    /// Sessions/segments using `label` move to `reassignTo` (nil = become Unlabeled), then label is deleted.
    /// Clears settings.defaultLabelID if it pointed to it (caller passes settings).
    static func deleteLabel(_ label: WorkLabel, reassignTo: WorkLabel?, settings: AppSettings, in context: ModelContext)
    static func mergeLabel(_ source: WorkLabel, into target: WorkLabel, settings: AppSettings, in context: ModelContext)
    static func deleteTag(_ tag: WorkTag, in context: ModelContext)
    /// Replace `source` with `target` on all sessions/segments/learning points (no duplicates), delete source.
    static func mergeTag(_ source: WorkTag, into target: WorkTag, in context: ModelContext)
    static func reorderLabels(_ labels: [WorkLabel])
}
```

### 3.7 `AuthService` and `KeychainStore`
```swift
enum AuthState: Equatable {
    case unknown
    case signedOut                     // → RootView shows WelcomeView
    case guest                         // "Continue without signing in"
    case signedIn(userID: String)
}

@MainActor @Observable
final class AuthService {
    private(set) var state: AuthState = .unknown
    private(set) var displayName: String?   // Apple only returns name/email on first sign-in → stored in Keychain
    private(set) var email: String?
    var lastError: String?
    var isSignedIn: Bool { get }            // state is .signedIn
    var needsWelcome: Bool { get }          // state == .signedOut

    /// Initial state, set synchronously in init:
    /// - Keychain "appleUserID" exists → .signedIn (optimistic).
    /// - Else UserDefaults "auth.guestMode" == true → .guest.
    /// - Else → .signedOut.
    /// Also observes ASAuthorizationAppleIDProvider.credentialRevokedNotification → signOut().
    init(keychain: KeychainStore = KeychainStore())
    /// Verifies the stored ID via ASAuthorizationAppleIDProvider().credentialState(forUserID:);
    /// .revoked/.notFound → signOut(). Network/entitlement errors keep the current state. Called at launch.
    func checkCredentialState() async
    /// For SignInWithAppleButton(onRequest:): request.requestedScopes = [.fullName, .email].
    func configure(_ request: ASAuthorizationAppleIDRequest)
    /// For SignInWithAppleButton(onCompletion:). Success: store user, fullName (formatted), email in Keychain,
    /// clear guest flag, state = .signedIn. Failure (not canceled): lastError = message
    /// (hint "Sign in with Apple isn't configured for this build — continue without signing in" when
    /// !Entitlements.hasSignInWithApple). ASAuthorizationError.canceled → ignore.
    func handleSignInResult(_ result: Result<ASAuthorization, Error>)
    /// Sets UserDefaults "auth.guestMode" = true, state = .guest.
    func continueWithoutSigningIn()
    /// Deletes Keychain items, clears guest flag, state = .signedOut. Never deletes data.
    func signOut()
}

struct KeychainStore {
    init(service: String = AppConstants.bundleID)
    func set(_ value: String, for key: String)   // kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlock; upsert
    func string(for key: String) -> String?
    func delete(_ key: String)
}
// Keychain keys: "appleUserID", "appleUserName", "appleUserEmail".
```

### 3.8 `AppSettings` (UserDefaults-backed; every property is a stored var whose `didSet` writes to defaults)
```swift
enum BackupInterval: String, CaseIterable, Identifiable, Codable {
    case off, every15Minutes, hourly, every6Hours, daily
    var id: String { rawValue }
    var displayName: String { get }
    var seconds: TimeInterval? { get }   // nil for .off
}

@MainActor @Observable
final class AppSettings {
    init(defaults: UserDefaults = .standard)
    /// Layout + compact, opacity, level, Spaces, hide-when-idle back to defaults; `overlayEnabled` is unchanged.
    func resetOverlayDefaults()
    func overlayShows(_ element: OverlayElement) -> Bool   // overlayLayout.contains(element)
    func resetOverlayLayout()                              // overlayLayout = OverlayElement.defaultLayout
    // properties below
}
```

The table lists every key. Property names are exact, and the UserDefaults key is `"settings." + propertyName`.

| Property | Type | Default | Used by |
|---|---|---|---|
| `defaultLabelID` | `UUID?` (stored as uuidString) | `nil` | engine.defaultLabel, C |
| `showMenuBarExtra` | `Bool` | `true` | App (MenuBarExtra isInserted), C |
| `menuBarShowsTimer` | `Bool` | `true` | MenuBarLabelView, engine tick |
| `menuBarShowLastTakeaway` | `Bool` | `true` | MenuBarPanelView |
| `showEndSessionSheet` | `Bool` | `true` | engine.stop |
| `confirmBeforeDiscard` | `Bool` | `true` | A |
| `pauseOnSleep` | `Bool` | `true` | engine |
| `pauseOnQuit` | `Bool` | `false` | engine |
| `longSessionWarningHours` | `Double` | `10` | A (banner "still running?") |
| `dailyGoalHours` | `Double` | `4` | C stats, A today |
| `weekStartsOnMonday` | `Bool` | `true` | C stats |
| `iCloudSyncEnabled` | `Bool` | `true` | PersistenceController (applies at next launch), C |
| `overlayEnabled` | `Bool` | `false` | OverlayPanelController (source of truth for visibility) |
| `overlayLayout` | `[OverlayElement]` (stored as `[String]` raw values) | `OverlayElement.defaultLayout` (migrated once from the round-1 `overlayShow…` keys, §11.2) | OverlayView / OverlayContent, OverlayLayoutEditor |
| `overlayCompact` | `Bool` | `false` | OverlayView (≈220pt wide vs 300pt) |
| `overlayOpacity` | `Double` | `0.95` (clamped 0.4…1.0) | OverlayPanelController |
| `overlayAlwaysOnTop` | `Bool` | `true` | OverlayPanelController (`.floating` vs `.normal` level) |
| `overlayShowOnAllSpaces` | `Bool` | `true` | OverlayPanelController |
| `overlayHideWhenIdle` | `Bool` | `false` | OverlayPanelController |
| `backupInterval` | `BackupInterval` (rawValue) | `.hourly` | BackupService |
| `backupRetentionCount` | `Int` | `10` (clamp 1…100) | BackupService |
| `backupIncludesAttachments` | `Bool` | `true` | BackupService |

Theme, appearance and accent are **not** in AppSettings. ThemeManager owns them (§4). Keyboard shortcuts are **not** in AppSettings either: `ShortcutStore` owns them (key `"shortcuts.overrides"`, §11.3).

The round-1 keys `settings.overlayShowTimer`, `…Label`, `…SegmentFocus`, `…Controls`, `…SplitButton`, `…NoteField`, `…LastTakeaway` and `…TodayTotal` are no longer properties. They are read once by the `overlayLayout` migration and otherwise left untouched (so a downgrade still works).

### 3.9 Export, import and backup

`Services/ExportDTOs.swift`:
```swift
import Foundation

struct ExportArchive: Codable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String          // CFBundleShortVersionString
    var includesAttachments: Bool
    var labels: [LabelDTO]
    var tags: [TagDTO]
    var sessions: [SessionDTO]
}
struct LabelDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var symbolName: String
    var sortIndex: Int; var isArchived: Bool; var createdAt: Date
}
struct TagDTO: Codable, Hashable {
    var id: UUID; var name: String; var colorHex: String; var labelID: UUID?
    var isArchived: Bool; var createdAt: Date
}
struct SessionDTO: Codable {
    var id: UUID; var title: String; var startedAt: Date; var endedAt: Date?
    var pauseIntervals: [PauseInterval]; var labelID: UUID?; var tagIDs: [UUID]
    var learningText: String; var overlaySummary: String; var showInOverlay: Bool
    var createdAt: Date; var modifiedAt: Date
    var segments: [SegmentDTO]; var notes: [NoteDTO]
    var attachments: [AttachmentDTO]; var learningPoints: [LearningPointDTO]
}
struct SegmentDTO: Codable {
    var id: UUID; var startedAt: Date; var endedAt: Date?; var sortIndex: Int
    var focus: String; var labelID: UUID?; var tagIDs: [UUID]
}
struct NoteDTO: Codable {
    var id: UUID; var createdAt: Date; var editedAt: Date?; var text: String; var segmentID: UUID?
}
struct AttachmentDTO: Codable {
    var id: UUID; var createdAt: Date; var filename: String; var caption: String; var uti: String
    var pixelWidth: Int; var pixelHeight: Int
    var data: Data?            // nil when exported without attachments
    var thumbnailData: Data?
}
struct LearningPointDTO: Codable {
    var id: UUID; var createdAt: Date; var text: String; var sortIndex: Int; var mastery: Int; var tagIDs: [UUID]
}
```

JSON coding:
- **Encoder:** `.iso8601` dates, `.base64` data, `[.prettyPrinted, .sortedKeys]`.
- **Decoder:** the matching strategies.
- Decoding rejects `formatVersion > currentFormatVersion`.

`Services/ExportService.swift`:
```swift
extension Notification.Name { static let worklogDataDidImport = Notification.Name("worklogDataDidImport") }

enum ImportMode { case merge, replace }   // merge = upsert by uuid; replace = delete everything first
struct ImportSummary: Equatable {
    var labels = 0, tags = 0, sessionsInserted = 0, sessionsUpdated = 0, attachments = 0
    var description: String { get }       // "Imported 12 sessions (3 updated), 5 labels, 9 tags."
}
enum DataTransferError: LocalizedError {
    case unsupportedVersion(Int), decodingFailed(String), sessionActive, writeFailed(String)
    var errorDescription: String? { get }
}

@MainActor @Observable
final class ExportService {
    init(container: ModelContainer)
    func makeArchive(includeAttachments: Bool) throws -> ExportArchive
    func jsonData(includeAttachments: Bool) throws -> Data
    /// Atomic write.
    func exportJSON(to url: URL, includeAttachments: Bool) throws
    /// Sessions CSV header (RFC 4180 quoting, ISO-8601 dates, tags joined by "; "):
    /// id,title,label,tags,startedAt,endedAt,activeMinutes,pausedMinutes,segmentCount,noteCount,learningPointCount,learningText
    func exportSessionsCSV(to url: URL) throws
    /// Header: sessionID,sessionTitle,segmentID,index,startedAt,endedAt,activeMinutes,label,tags,focus
    func exportSegmentsCSV(to url: URL) throws
    static func defaultFilename(ext: String) -> String     // "Worklog-Export-2026-10-07.json"
    func decodeArchive(from url: URL) throws -> ExportArchive
    /// .replace throws .sessionActive if any session has endedAt == nil. Merge upserts labels/tags/sessions by uuid;
    /// an existing session's children are replaced by the DTO's. Saves, posts .worklogDataDidImport.
    func importArchive(_ archive: ExportArchive, mode: ImportMode) throws -> ImportSummary
    func importArchive(from url: URL, mode: ImportMode) throws -> ImportSummary
    /// Deletes all model objects (blocked while a session is active → .sessionActive). Posts .worklogDataDidImport.
    func deleteAllData() throws
}
```

`Services/BackupService.swift`:
```swift
enum BackupReason: String { case scheduled, onQuit, manual, beforeRestore }
struct BackupFile: Identifiable, Hashable {
    let url: URL; let date: Date; let sizeBytes: Int64; let reason: String
    var id: URL { url }
}

@MainActor @Observable
final class BackupService {
    private(set) var lastBackupDate: Date?
    private(set) var backups: [BackupFile] = []      // newest first
    private(set) var isWorking = false
    var lastError: String?
    var backupsDirectory: URL { AppConstants.backupsURL }

    init(exporter: ExportService, settings: AppSettings)
    /// Observes ModelContext.didSave (marks dirty; starts dirty) and settings.backupInterval (withObservationTracking);
    /// schedules a repeating Timer; each fire: if dirty → backupNow(.scheduled).
    func startScheduling()
    /// Synchronous: archive (attachments per settings) → write
    /// "Worklog-Backup-yyyy-MM-dd'T'HH-mm-ss-<reason>.json" atomically → prune to backupRetentionCount → refresh list.
    @discardableResult func backupNow(reason: BackupReason) -> URL?
    func refreshList()
    /// Makes a .beforeRestore backup first, then exporter.importArchive(from:mode:).
    func restore(from backup: BackupFile, mode: ImportMode) throws -> ImportSummary
    func revealInFinder()        // NSWorkspace.shared.activateFileViewerSelecting
    func delete(_ backup: BackupFile)
}
```

### 3.10 `SearchService`
```swift
struct SearchSnippet: Equatable {
    enum Field: String { case title, label, tag, segmentFocus, note, learning, learningPoint, attachmentCaption }
    let field: Field
    let text: String      // ≤ 120 chars, centered on the first match, "…" added when truncated
}

enum SearchService {
    /// Lowercased, diacritic-folded, whitespace-split, empty removed. Quoted phrases ("deep work") are one term.
    static func terms(from query: String) -> [String]
    /// AND across terms; each term must match (case/diacritic-insensitive substring) at least one of: title, label name,
    /// session tags, segment labels/tags/focus, note texts, learningText, overlaySummary, learning point texts + tags,
    /// attachment captions/filenames.
    static func matches(_ session: WorkSession, terms: [String]) -> Bool
    static func matches(_ point: LearningPoint, terms: [String]) -> Bool   // text, tags, session title
    /// Empty query → input unchanged.
    static func filter(_ sessions: [WorkSession], query: String) -> [WorkSession]
    /// First match for the first term in field order above (title last-priority: skip if only title matched).
    static func snippet(for session: WorkSession, query: String) -> SearchSnippet?
}
```

### 3.11 `AttachmentImporter`
```swift
struct ImportedImage: Sendable { let data: Data; let filename: String }
enum AttachmentImportError: LocalizedError { case unreadableImage, encodingFailed; var errorDescription: String? { get } }

@MainActor enum AttachmentImporter {
    static let maxPixelDimension: Int = 2048
    static let thumbnailPixelDimension: Int = 400
    static let jpegQuality: Double = 0.8
    /// Uses ImageIO: CGImageSourceCreateThumbnailAtIndex(kCGImageSourceThumbnailMaxPixelSize, CreateThumbnailWithTransform,
    /// CreateThumbnailFromImageAlways). Output: PNG if source has alpha, else JPEG(0.8). Fills pixel size, thumbnail, uti.
    /// Returned Attachment is NOT inserted.
    static func makeAttachment(fromImageData data: Data, filename: String) throws -> Attachment
    static func makeAttachment(fromFileAt url: URL) throws -> Attachment
    /// NSOpenPanel (images, multiple selection).
    static func chooseImageFiles() -> [URL]
    /// Reads image data/file URLs from the pasteboard (for ⌘V / .onPasteCommand).
    static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ImportedImage]
    /// For .onDrop(of: [.image, .fileURL]) providers; runs off-main, returns raw data.
    nonisolated static func loadImages(from providers: [NSItemProvider]) async -> [ImportedImage]
    /// make + insert + link to session + touch + save. Skips failures, sets no error UI (returns successes).
    @discardableResult
    static func add(_ images: [ImportedImage], to session: WorkSession, in context: ModelContext) -> [Attachment]
    /// Drop / paste (round 4 final): `prepareImages` off the main thread, then insert/link/save on the main actor
    /// only if `session` is still live. Named apart from `add` so an `await` call can't resolve to the sync one.
    @discardableResult
    static func addInBackground(_ images: [ImportedImage], to session: WorkSession,
                                in context: ModelContext) async -> [Attachment]
    /// Open panel, then `prepareFiles` off the main thread; inserts/saves on the main actor only if `session` is
    /// still live. Call with `await` from a Task. (The synchronous overload was removed in round 4 final.)
    @discardableResult
    static func addFromOpenPanel(to session: WorkSession, in context: ModelContext) async -> [Attachment]
    /// `prepare(imageData:filename:)` / `prepare(fileAt:)` for each item, skipping (and logging) failures.
    nonisolated static func prepareImages(_ images: [ImportedImage]) -> [PreparedImage]
    nonisolated static func prepareFiles(_ urls: [URL]) -> [PreparedImage]
    /// Downscale + encode without creating a model (Sendable `PreparedImage`); safe off the main thread.
    nonisolated static func prepare(imageData data: Data, filename: String) throws -> PreparedImage
    nonisolated static func prepare(fileAt url: URL) throws -> PreparedImage
    static func makeAttachment(_ image: PreparedImage) -> Attachment
    /// NSSavePanel; writes `data`.
    static func saveToDisk(_ attachment: Attachment)
}
```

### 3.12 `WindowRouter`, `SidebarItem`, `AppServices`
```swift
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, history, learning, stats, settings
    var id: String { rawValue }
    /// The List rows: [.today, .history, .learning, .stats] (Settings is pinned in the sidebar footer).
    static let primaryItems: [SidebarItem]
    var title: String { get }        // "Today", "History", "Learning", "Stats", "Settings"
    var systemImage: String { get }  // "timer", "clock.arrow.circlepath", "lightbulb", "chart.bar.xaxis", "gearshape"
}

@MainActor @Observable
final class WindowRouter {
    var selection: SidebarItem = .today
    /// History's list selection (HistoryView binds its List selection to this).
    var selectedSessionID: PersistentIdentifier?
    /// Incremented on each request; LiveSessionView observes with .onChange and focuses the note field / opens split UI.
    private(set) var noteFocusRequest: Int = 0
    private(set) var splitRequest: Int = 0
    /// Incremented by requestDiscard(); the Today page observes it and runs its discard flow.
    private(set) var discardRequest: Int = 0

    /// Settings tab to select (a `SettingsTab` rawValue); SettingsView consumes it and sets it back to nil.
    var settingsTabRequest: String?

    /// Round 4b: sheets in the main window other than the review (Split, image viewer, New Profile…) call
    /// childSheetDidAppear()/childSheetDidDisappear() (never below 0). RootView holds the review back while > 0.
    /// Confirmation dialogs and alerts use `View.countsAsChildSheet(isPresented:)` (Shared/ProfileSwitcher.swift;
    /// replaces LiveSession's `liveChildSheet`): History, segment, image and note dialogs as well as the live ones.
    private(set) var presentedChildSheets: Int = 0
    /// Bumped by requestReview(); RootView re-presents a pending review (nil → session toggle).
    private(set) var reviewRequest: Int = 0
    /// Bumped by showSession(_:); HistoryView clears its filters and search.
    private(set) var historyFilterResetRequest: Int = 0
    /// Set by AppServices. While auth.needsWelcome, requestNoteFocus/Split/Discard only show the window (no counter
    /// bump, no selection change), so nothing fires after sign-in.
    weak var auth: AuthService?

    /// Called by RootView, MenuBarLabelView and MenuBarPanelView in .onAppear with @Environment(\.openWindow).
    func register(openWindow: OpenWindowAction)
    /// NSApp.activate() + openWindow(id: WindowID.main) (brings an existing Window to front, or reopens it).
    func showMainWindow()
    /// selection = .settings; showMainWindow(). Works when the main window was closed.
    func showSettings()
    /// settingsTabRequest = tab; showSettings()
    func showSettings(tab: String)
    func show(_ item: SidebarItem)                 // selection = item; showMainWindow()
    func showSession(_ session: WorkSession)       // .history + selectedSessionID = session.persistentModelID
    func requestNoteFocus()                        // selection = .today; showMainWindow(); noteFocusRequest += 1
    func requestSplit()                            // selection = .today; showMainWindow(); splitRequest += 1
    func requestDiscard()                          // selection = .today; showMainWindow(); discardRequest += 1
    func stopSession(_ engine: SessionEngine)      // the single stop path: stop; showMainWindow() if a review is pending
    func requestReview()                           // showMainWindow(); leave Settings; reviewRequest += 1
    func childSheetDidAppear()
    func childSheetDidDisappear()
}

@MainActor
final class AppServices {
    static let shared = AppServices()
    static let preview = AppServices(inMemory: true)   // populated by PreviewData
    let settings: AppSettings
    let shortcuts: ShortcutStore          // same UserDefaults as `settings` (ephemeral suite when inMemory)
    let persistence: PersistenceController
    let themeManager: ThemeManager
    let auth: AuthService
    let router: WindowRouter
    let engine: SessionEngine
    let exporter: ExportService
    let backups: BackupService
    let overlay: OverlayPanelController
    var container: ModelContainer { persistence.container }

    /// Order: settings → shortcuts(defaults:) → persistence(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory:) → themeManager → auth →
    /// router → engine(context: mainContext) → exporter → backups → overlay(settings:);
    /// SeedData.seedIfNeeded + deduplicate (or PreviewData.populate if inMemory);
    /// engine.restoreActiveSession(); overlay.install(services: self).
    init(inMemory: Bool = false)
}

extension View {
    /// Injects every service + modelContainer + theme. Apply to EVERY scene root and to the overlay hosting view.
    func withAppServices(_ services: AppServices) -> some View
    // = self.environment(services.settings).environment(services.shortcuts).environment(services.persistence)
    //   .environment(services.sync).environment(services.themeManager)
    //   .environment(services.auth).environment(services.router).environment(services.engine)
    //   .environment(services.exporter).environment(services.backups).environment(services.overlay)
    //   .modelContainer(services.container).worklogThemed(services.themeManager)
}
```

### 3.13 `OverlayPanelController`
```swift
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }    // lets the note TextField receive input
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class OverlayPanelController {
    private(set) var isVisible = false
    init(settings: AppSettings)
    /// Builds the panel once:
    /// - styleMask [.borderless, .nonactivatingPanel]
    /// - isFloatingPanel = true, hidesOnDeactivate = false, isMovableByWindowBackground = true
    /// - backgroundColor = .clear, isOpaque = false, hasShadow = true
    /// - contentViewController = NSHostingController(rootView: OverlayView().withAppServices(services))
    ///   with sizingOptions = [.preferredContentSize] (the window tracks the SwiftUI ideal size)
    /// - setFrameAutosaveName("WorklogOverlay"); default position top-right of the main screen's visibleFrame
    /// Then starts withObservationTracking on the overlay settings + engine.isActive and re-applies:
    /// - alphaValue = overlayOpacity
    /// - level = overlayAlwaysOnTop ? .floating : .normal
    /// - collectionBehavior = overlayShowOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    /// - visible = overlayEnabled && !(overlayHideWhenIdle && !engine.isActive)
    func install(services: AppServices)
    func show()      // settings.overlayEnabled = true
    func hide()      // settings.overlayEnabled = false
    func toggle()
    /// Round 4 final (replaces OverlayView's `OverlayKeyFocus`): makes the panel key so a field in it takes typing
    /// right away, without activating Worklog.
    func makePanelKey()
    /// Ends editing and gives up key status: to a Worklog window when Worklog is active and has one that can take
    /// the keyboard, else back to the frontmost app (deactivating Worklog when it has nothing else to type into).
    /// Runs on the next main-actor turn. Never call `panel.resignKey()` directly.
    func releaseKeyFocus()
}
```

### 3.14 `Utilities/Formatting.swift` (CORE): exact helpers
```swift
extension TimeInterval {           // (Double)
    /// "05:07" when < 1h, "1:05:07" otherwise; negatives → 0.
    var formattedClock: String { get }
    /// "45s" (<1m), "12m" (<1h), "1h 05m", "2h" (zero minutes).
    var formattedShort: String { get }
}
extension Date {
    var startOfDay: Date { get }                 // Calendar.current
    var startOfNextDay: Date { get }
    var dayInterval: DateInterval { get }        // [startOfDay, startOfNextDay)
    func isSameDay(as other: Date) -> Bool
    /// "Today", "Yesterday", "Monday, Oct 5" (+ ", 2025" if not current year).
    var relativeDayTitle: String { get }
    var shortTime: String { get }                // .formatted(date: .omitted, time: .shortened)
    var shortDateTime: String { get }            // .formatted(date: .abbreviated, time: .shortened)
}
extension DateInterval {
    /// Never traps: end is max(start, end).
    init(safeStart start: Date, end: Date)
}
extension String {
    var trimmed: String { get }                  // whitespacesAndNewlines
    var isBlank: Bool { get }
    var nilIfBlank: String? { get }
}
```

`Utilities/Log.swift`:
```swift
import os
enum Log {
    static let persistence = Logger(subsystem: AppConstants.bundleID, category: "persistence")
    static let engine = Logger(subsystem: AppConstants.bundleID, category: "engine")
    static let backup = Logger(subsystem: AppConstants.bundleID, category: "backup")
    static let auth = Logger(subsystem: AppConstants.bundleID, category: "auth")
    static let ui = Logger(subsystem: AppConstants.bundleID, category: "ui")
}
```

### 3.15 `PreviewData` (CORE)
```swift
@MainActor enum PreviewData {
    /// Seeds labels/tags + ~12 ended sessions over the past 3 weeks (multi-segment, notes, learning points with tags,
    /// one session with showInOverlay + overlaySummary) and NO active session.
    static func populate(_ context: ModelContext)
    /// First ended session (by startedAt desc) in AppServices.preview's context.
    static var sampleSession: WorkSession { get }
}
```

Usage: `#Preview { SessionDetailView(session: PreviewData.sampleSession).withAppServices(.preview) }`.

---

## 4. Design system (DES): required public API

The designer may add more but must provide **exactly** these signatures. Every visual value comes from `Theme`. Feature code must not hard-code colors, fonts or radii, except `Color(hex:)` for label and tag colors (use `label.color` / `tag.color`).

### 4.1 `ThemeID.swift`
```swift
enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case graphite, paper, meadow            // FINAL case names; add new styles by adding cases
    var id: String { rawValue }
    var displayName: String { get }
    var summary: String { get }             // one-line description for Settings
}
enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String { get }
    var nsAppearance: NSAppearance? { get } // nil, .aqua, .darkAqua
}
enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case themeDefault, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var displayName: String { get }
    var color: Color? { get }               // nil for .themeDefault
}
```

### 4.2 `Theme.swift`
```swift
struct Theme {
    var id: ThemeID
    var colorScheme: ColorScheme
    // Surfaces
    var background: Color          // main window content background
    var sidebarBackground: Color
    var surface: Color             // cards
    var elevatedSurface: Color     // sheets, popovers, overlay/menubar panel fill
    var insetSurface: Color        // text fields, wells, note composer
    // Text
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    // Accent & status
    var accent: Color              // already resolved with AccentChoice
    var onAccent: Color            // text/icons on accent
    var separator: Color
    var success: Color
    var warning: Color
    var danger: Color
    var timerRunning: Color
    var timerPaused: Color
    var chartPalette: [Color]      // ≥ 8 colors, used for series without a label color
    // Materials
    var panelMaterial: Material    // overlay + menu bar panel background
    var usesMaterials: Bool        // false → use elevatedSurface instead of material
    // Typography
    var largeTitleFont: Font
    var titleFont: Font
    var headlineFont: Font
    var bodyFont: Font
    var calloutFont: Font
    var captionFont: Font
    var labelFont: Font            // chips, badges
    var monoFont: Font
    var timerHeroFont: Font        // Today page big timer (monospaced digits)
    var timerFont: Font            // overlay / menu panel
    var timerCompactFont: Font     // rows, compact overlay
    // Shape
    var radiusS: CGFloat
    var radiusM: CGFloat
    var radiusL: CGFloat
    var borderWidth: CGFloat
    var shadowColor: Color
    var shadowRadius: CGFloat
    var shadowY: CGFloat
    // Spacing
    var spacingXS: CGFloat  // ~4
    var spacingS: CGFloat   // ~8
    var spacingM: CGFloat   // ~12
    var spacingL: CGFloat   // ~16
    var spacingXL: CGFloat  // ~24
    var spacingXXL: CGFloat // ~32

    static func make(_ id: ThemeID, colorScheme: ColorScheme, accent: AccentChoice = .themeDefault) -> Theme
    static let fallback: Theme   // .make(.default, colorScheme: .light)
}
```
Per-theme definitions go in `Themes/PaperTheme.swift`, `GraphiteTheme.swift` and `MeadowTheme.swift`, for example `extension Theme { static func paper(_ scheme: ColorScheme) -> Theme }`. `make` switches on `id` and then applies `accent.color` if it is non-nil.

### 4.3 `ThemeManager.swift`
```swift
@MainActor @Observable
final class ThemeManager {
    init(defaults: UserDefaults = .standard)
    var themeID: ThemeID           // key "appearance.themeID", default ThemeID.default (.graphite)
    var appearance: AppearanceMode // key "appearance.mode", default .system; didSet → applyAppearance()
    var accent: AccentChoice       // key "appearance.accent", default .themeDefault
    func theme(for colorScheme: ColorScheme) -> Theme
    /// NSApplication.shared.appearance = appearance.nsAppearance (affects all windows, menu bar panel, overlay).
    func applyAppearance()
}
```

### 4.4 `ThemeEnvironment.swift`
```swift
extension EnvironmentValues { var theme: Theme { get set } }   // default Theme.fallback
enum SurfaceLevel { case background, sidebar, surface, elevated, inset }
extension View {
    /// Reads @Environment(\.colorScheme), injects \.theme = manager.theme(for:), applies .tint(theme.accent).
    func worklogThemed(_ manager: ThemeManager) -> some View
    func themedBackground(_ level: SurfaceLevel = .background) -> some View
    /// surface fill + radiusM + border + shadow + padding(spacingL)
    func cardStyle() -> some View
}
```
Views read the theme with `@Environment(\.theme) private var theme`.

### 4.5 `Color+Hex.swift` and `Model+Color.swift`
```swift
extension Color {
    /// "#RRGGBB", "RRGGBB" or "#RRGGBBAA"; invalid → gray.
    init(hex: String)
    /// sRGB "#RRGGBB" (via NSColor).
    var hexString: String { get }
}
enum LabelPalette {
    static let hexColors: [String]   // ≥ 12 curated label/tag colors
    static let symbols: [String]     // ≥ 30 curated SF Symbols for labels
}
extension WorkLabel { var color: Color { get } }   // Color(hex: colorHex)
extension WorkTag { var color: Color { get } }
```

### 4.6 Components (exact inits)
```swift
struct Card<Content: View>: View { init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) }
struct SectionHeader<Trailing: View>: View {
    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing)
}
extension SectionHeader where Trailing == EmptyView { init(_ title: String, systemImage: String? = nil) }
enum BadgeSize { case small, regular, large }
struct LabelBadge: View { init(label: WorkLabel?, size: BadgeSize = .regular) }   // nil → "Unlabeled"
struct TagChip: View {
    init(tag: WorkTag, isSelected: Bool = false, onRemove: (() -> Void)? = nil)
    init(name: String, colorHex: String, isSelected: Bool = false, onRemove: (() -> Void)? = nil)
}
struct ColorDot: View { init(hex: String, size: CGFloat = 8) }
enum TimerTextStyle { case hero, large, medium, compact }
/// Pure display (monospaced digits, formattedClock). Caller wraps in TimelineView.
struct TimerText: View { init(_ interval: TimeInterval, style: TimerTextStyle = .large, isPaused: Bool = false) }
struct PrimaryButtonStyle: ButtonStyle { init() }
struct QuietButtonStyle: ButtonStyle { init() }
struct DestructiveButtonStyle: ButtonStyle { init() }
struct IconButtonStyle: ButtonStyle { init(size: CGFloat = 28) }
struct EmptyStateView: View {
    init(title: String, systemImage: String, message: String? = nil,
         actionTitle: String? = nil, action: (() -> Void)? = nil)
}
struct SearchField: View { init(text: Binding<String>, prompt: String = "Search") }
struct StatTile: View { init(title: String, value: String, systemImage: String? = nil, caption: String? = nil) }
struct FlowLayout: Layout { init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) }
enum BannerStyle { case info, success, warning, error }
struct InlineBanner: View {
    init(_ message: String, systemImage: String? = nil, style: BannerStyle = .info,
         actionTitle: String? = nil, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil)
}
struct ThemePreviewSwatch: View { init(themeID: ThemeID, isSelected: Bool) }
```
Usage is always explicit, for example `.buttonStyle(PrimaryButtonStyle())`.

### 4.7 Shared data-bound controls (`Worklog/Shared/`, DES)
```swift
/// Menu-style picker of non-archived labels (sorted by sortIndex) with color dot + symbol; optional "None".
/// Shows the current selection even if archived.
struct LabelPicker: View { init(selection: Binding<WorkLabel?>, includeNone: Bool = true, title: String = "Label") }
/// Chips for selected tags (removable) + "+" popover: search field, tags scoped to `scopeLabel` first, then global;
/// if allowsCreate, "Create “x”" → TaskonomyOps.createTag(name:in:) via @Environment(\.modelContext).
struct TagPicker: View { init(selection: Binding<[WorkTag]>, scopeLabel: WorkLabel? = nil, allowsCreate: Bool = true) }
/// Read-only FlowLayout of TagChip.
struct TagChipsRow: View { init(tags: [WorkTag]) }
/// Read-only note row: time (shortTime), text (lineLimit 6, expandable), optional segment focus caption.
struct NoteRow: View { init(note: Note, showsSegment: Bool = false) }
struct LabelColorPicker: View { init(hex: Binding<String>) }      // palette swatches + ColorPicker (custom)
struct SymbolPicker: View { init(symbolName: Binding<String>) }   // grid of LabelPalette.symbols
```
(The `TagPicker` comment means `TaxonomyOps.createTag`.)

To bind optional to-many arrays, callers use the model accessors: `@Bindable var session` then `TagPicker(selection: $session.tagList)`.

---

## 5. Scenes, navigation and root views

### 5.1 `WorklogApp.swift` (CORE)
```swift
@main
struct WorklogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        Window("Worklog", id: WindowID.main) {
            RootView().withAppServices(services)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)   // the window minimum is the root's 900 × 600, never a child's
        .commands { WorklogCommands(services: services) }

        // No Settings scene: Settings is a page of the main window (SidebarItem.settings, §11.4).

        MenuBarExtra(isInserted: Bindable(services.settings).showMenuBarExtra) {
            MenuBarPanelView().withAppServices(services)
        } label: {
            MenuBarLabelView().withAppServices(services)
        }
        .menuBarExtraStyle(.window)
    }
}
```

`AppDelegate` (CORE):
- **applicationDidFinishLaunching:**
  - `themeManager.applyAppearance()`
  - `NSApp.registerForRemoteNotifications()`
  - `engine.startObservingSystemEvents()`
  - `backups.startScheduling()`
  - `Task { await auth.checkCredentialState() }`
  - overlay shows if `settings.overlayEnabled`
- **applicationShouldTerminate:** `engine.prepareForTermination()`, then `backups.backupNow(reason: .onQuit)`, then `.terminateNow`.
- **applicationShouldTerminateAfterLastWindowClosed:** `false`. The menu bar keeps the app alive.
- **applicationShouldHandleReopen:** `router.showMainWindow()` when there are no visible windows; returns `true`.
- **On `didBecomeActive`:** `SeedData.deduplicate`, then `engine.reconcile()`. The engine installs this observer itself.

### 5.2 `RootView` (CORE)
- If `auth.needsWelcome`, show `WelcomeView()` full-window. While `.unknown`, show the main UI.
  - While `auth.needsWelcome` and `router.selection == .settings` (⌘, or Welcome's "Settings…"/"Recover…"), show `SettingsView()` full-window under a "Back" button that sets `selection = .today`. When `needsWelcome` changes while `.settings` is selected, selection goes back to `.today`.
- **End-of-session sheet:** presented from `engine.pendingEndSession`. If it becomes set while Settings is shown, RootView first selects `.today` (Settings' own sheets would block it) and presents the review ~0.4 s later. Once the review is on screen, navigating to Settings doesn't hide it. Round 4b: the item is also nil while `router.presentedChildSheets > 0` (another sheet is up in this window) and is re-presented ~0.4 s after the last one closes; `router.reviewRequest` ("Review…" in the menu bar/overlay) does the same nil → session toggle.
- Otherwise show a `NavigationSplitView`:
  - **Sidebar:** a `List(selection:)` over `SidebarItem.primaryItems`, `.listStyle(.sidebar)`, using `Label(item.title, systemImage: item.systemImage)`. The selection binding reads `nil` while `router.selection == .settings`.
  - **Pinned bottom inset** (`.safeAreaInset(edge: .bottom, spacing: 0)`, sidebar background), never a VStack sibling of the List:
    - **Mini status row:** shows the live timer via `LiveTicker` plus the label when `engine.isActive`. Clicking it selects `.today`.
    - **Footer:** account icon + name ("Guest") as one plain button → `router.showSettings(tab: "account")`; a gear button (`IconButtonStyle(size: 24)`) → `router.selection = .settings`, shown as `gearshape.fill` in the accent colour (and `.isSelected`) while Settings is shown.
  - **Sidebar background:** `themedBackground(.sidebar)`.
- **Detail column:** a min-size barrier: `VStack(spacing: 0) { bannerStack; detail.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity) }.frame(minWidth: 0, …).clipped().themedBackground(.background)`, so no page's data-dependent minimum size can grow or move the window.
- **Detail switch:**
  - `.today` → `LiveSessionView()`
  - `.history` → `HistoryView()`
  - `.learning` → `LearningView()`
  - `.stats` → `StatsView()`
  - `.settings` → `SettingsView()`
- **End-of-session sheet:** `.sheet(item: Binding(get: { engine.pendingEndSession }, set: { if $0 == nil { engine.completeReview() } })) { EndSessionSheet(session: $0) }`
- **On appear:** `.onAppear { router.register(openWindow: openWindow) }`
- **Storage banner:** if `persistence.storeMode` is `.localOnly`, show a dismissible `InlineBanner` (info) at the top of the detail; "Details…" opens Settings ▸ Data when the store belongs to another CloudKit environment (`persistence.environmentMismatch`), else Account. If it is `.inMemory`, show a persistent error banner ("Your data couldn’t be opened. Changes won’t be saved.") with "Restore…", which calls `router.showSettings(tab: "data")`; for a store from a newer Worklog (`isStoreFromNewerVersion`) it reads "Your data needs a newer Worklog. Changes won’t be saved." with no action (Recover is not allowed). A sync error shows "iCloud sync failed; changes kept on this Mac." with "Details…" → `router.showSettings(tab: "account")`. The launch notice (info) gets "Restore…" → Data when `persistence.launchNoticeOffersRestore` (data shrank after an account change, a restore failed).

### 5.3 Root views each feature agent MUST define (exact names and inits)

Round 2 changed several of these views (in-app Settings, the overlay layout editor, History's layout); §11 and `docs/DESIGN.md` describe the current behaviour where they differ from the round-1 notes below.

| Type | Init | Owner | Shown by |
|---|---|---|---|
| `LiveSessionView` | `init()` | A | RootView `.today` |
| `EndSessionSheet` | `init(session: WorkSession)` | A | RootView sheet |
| `MenuBarPanelView` | `init()` | A | MenuBarExtra content (fixed width 320) |
| `MenuBarLabelView` | `init()` | A | MenuBarExtra label |
| `OverlayView` | `init()` | A | OverlayPanelController hosting controller |
| `HistoryView` | `init()` | B | RootView `.history` |
| `SessionDetailView` | `init(session: WorkSession)` | B | HistoryView (and anyone) |
| `LearningsEditor` | `init(session: WorkSession, style: LearningsEditorStyle = .full)` | B | SessionDetailView, EndSessionSheet (A uses `.compact`) |
| `LearningsEditorStyle` | `enum { case full, compact }` | B | — |
| `LearningView` | `init()` | C | RootView `.learning` |
| `StatsView` | `init()` | C | RootView `.stats` |
| `SettingsView` | `init()` | C | RootView `.settings` (in-app; there is no `Settings` scene) |
| `WelcomeView` | `init()` | C | RootView gate |

**Feature A.**
- **`LiveSessionView`, idle state:**
  - start form: LabelPicker defaulting to `engine.defaultLabel()`, TagPicker, focus field, Start button
  - last takeaway card
  - today total vs `dailyGoalHours`
  - today's sessions, which call `router.showSession` when clicked
- **`LiveSessionView`, active state:**
  - hero timer and current-segment timer
  - label and focus, editable via `updateCurrentSegment`
  - Pause/Resume, Split (popover: label, tags, focus), Stop, Discard (with confirm)
  - segment strip
  - note composer (Return adds; FocusState driven by `router.noteFocusRequest`) and live notes list (NoteRow)
  - optional "Attach image" via `await AttachmentImporter.addFromOpenPanel`; drop/paste via `await AttachmentImporter.addInBackground`
  - banners for `autoPauseReason` and long-running sessions ("Stop at last activity", which calls `engine.stop(at: session.lastActivityDate)`)
  - `splitRequest` opens the split popover
- **`EndSessionSheet`:**
  - fields: title, LabelPicker (changes via `SessionEditor.setPrimaryLabel`), session TagPicker
  - summary: duration, paused time, segments, notes count
  - `LearningsEditor(session:style:.compact)`
  - buttons:
    - Save: default action ⌘↩, calls `engine.completeReview()`
    - Resume: `engine.resumePendingSession()`
    - Discard: confirm, then `engine.discardPendingSession()`
  - Esc counts as Save as-is.
- **`MenuBarPanelView`:**
  - status and timer, label, Start (default label) or Pause/Resume/Split/Stop
  - quick note field
  - takeaway, if `menuBarShowLastTakeaway`
  - today total
  - Show/Hide overlay toggle
  - "Open Worklog" (`router.showMainWindow`), Settings (`router.showSettings`), Quit
  - After Stop, call `router.showMainWindow()`. It also registers `openWindow`.
- **`MenuBarLabelView`:**
  - `Text("\(Image(systemName: icon)) \(engine.elapsed(at: engine.tick).formattedClock)")` when active and `menuBarShowsTimer`, else only the icon
  - icon: `"timer"` when idle, `"record.circle"` when running, `"pause.circle"` when paused
  - `.onAppear` registers `openWindow` with the router
- **`OverlayView`:**
  - fixed width: 300, or 220 when `overlayCompact`; height is intrinsic
  - rounded `theme.panelMaterial` background
  - sections follow the overlay toggles
  - Stop calls `router.showMainWindow()`
  - when idle it shows a Start button and the takeaway
  - a close (x) button calls `overlay.hide()`

**Feature B.**
- **`HistoryView`:**
  - `@Query(filter: #Predicate<WorkSession> { $0.endedAt != nil }, sort: \WorkSession.startedAt, order: .reverse)`
  - search via `SearchService.filter` (debounce 150 ms)
  - sort via a `HistorySort` enum: `dateNewest`, `dateOldest`, `longest`, `shortest`, `labelAZ`. Length sorting uses `storedActiveDuration`; label sorting is done in memory.
  - optional label filter chips
  - rows grouped by `relativeDayTitle` showing title, LabelBadge, duration, tags and a search snippet
  - **Layout:** an `HStack` with the list (selection bound to `router.selectedSessionID`, user-draggable width) on the left, a 1 pt divider, and `SessionDetailView` on the right (or an EmptyStateView) in a 0-minimum frame (§11.5)
  - Delete uses confirm, then `SessionEditor.deleteSession`
  - a "Live session in progress" row at the top links to `.today` when `engine.isActive`
- **`SessionDetailView`:**
  - header: editable title, date, start/end time editing via `SessionEditor.setTimes`, label, tags
  - segments: list and timeline. Edit each segment's label, tags and focus; split at a time (sheet with DatePicker clamped inside the segment); merge; delete; move boundary.
  - notes: add with a timestamp, edit, delete
  - attachments: grid with open panel, paste (`.onPasteCommand`), drop (`.onDrop`), caption, quick-look style viewer, save, delete
  - `LearningsEditor`
- **`LearningsEditor`:**
  - `learningText`
  - `overlaySummary`: a TextField with a 140-character guidance counter. Typing a non-blank summary turns `showInOverlay` on.
  - `showInOverlay` toggle
  - learning points: add, edit, delete, reorder; TagPicker per point; mastery 1–5 control

**Feature C.**
- **`LearningView`:**
  - tag list showing counts for "All", "Untagged" and each tag
  - per tag:
    - BarMark chart of points per week
    - LineMark of average mastery, if any is rated
    - chronological timeline grouped by month: text, date, session title (click → `router.showSession`)
    - each session's `learningText` as context
  - search
- **`StatsView`:**
  - range picker: 7D, 30D, 90D, 1Y, All
  - StatTiles: total, sessions, average length, longest, streak
  - daily or weekly stacked BarMark by label, from segment `activeDuration(in:)`
  - SectorMark label share
  - top tags by time and by count
  - weekday × hour heatmap (RectangleMark)
  - daily goal RuleMark
  - all logic lives in `StatsCalculator`
- **`SettingsView`:** a page of the main window (sidebar footer gear, ⌘,) with a pill tab bar (`SettingsTab`: General, Appearance, Overlay, Shortcuts, Profiles, Labels & Tags, Account, Data). Original tab contents:
  - **General:** default label, menu bar, end sheet, pause on sleep/quit, goal, week start
  - **Appearance:** ThemePreviewSwatch grid, appearance mode, accent
  - **Overlay:** all overlay toggles, opacity slider, show/hide button
  - **Labels & Tags:** reorder, create, edit (name, LabelColorPicker, SymbolPicker), archive, delete with reassign, tag create/rename/color/parent label/merge/delete
  - **Account:** status, SignInWithAppleButton, sign out, explanation of iCloud vs. Apple ID, `storeMode` and iCloud sync toggle (requires relaunch)
  - **Data:** export JSON (with/without images) and CSVs via NSSavePanel; import JSON (merge/replace with confirm) via NSOpenPanel; backups list (backup now, restore, reveal, delete, interval, retention, include attachments); delete all data (double confirm)
  - Frame about 680×520.
- **`WelcomeView`:** pitch, `SignInWithAppleButton(.signIn, onRequest: auth.configure, onCompletion: auth.handleSignInResult)`, "Continue without signing in", a note about iCloud, and any error.

### 5.4 Commands and keyboard shortcuts (CORE `WorklogCommands`)

`CommandMenu("Session")` uses static titles, because Commands don't reliably observe state. Actions do nothing when they don't apply. Every shortcut below except ⌘, is a **default**: the user can change it (`ShortcutStore`, §11.3). Each item is a private `ShortcutCommandButton` View that reads `store.shortcut(for:)` in its own body, so changes apply to the menus immediately.

| Action | Shortcut | Behavior |
|---|---|---|
| Settings… (app menu) | ⌘, (fixed) | `router.showSettings()` (`CommandGroup(replacing: .appSettings)`; required, since there is no Settings scene) |
| Start / Stop Session | ⌘⇧S | active → `engine.stop()` + `router.showMainWindow()`; else `engine.start(label: engine.defaultLabel())` |
| Pause / Resume | ⌘⇧P | `engine.togglePause()` |
| Add Note… | ⌘⇧N | `router.requestNoteFocus()` |
| Split Segment… | ⌘⇧D | `router.requestSplit()` |
| Toggle Overlay | ⌘⇧O | `overlay.toggle()` |
| Discard Session… | (none) | when `engine.isActive`: `router.requestDiscard()`; the Today page runs its discard flow (confirmation when `settings.confirmBeforeDiscard`) |
| Today / History / Learning / Stats | ⌘1 / ⌘2 / ⌘3 / ⌘4 | `router.show(...)` (`CommandGroup(after: .sidebar)`) |

These shortcuts don't collide with anything:
- The app has no document or printing commands, so ⌘⇧S (Save As) and ⌘⇧P (Page Setup) are free.
- ⌘⇧N, ⌘⇧D and ⌘⇧O are unused in this app.
- ⌘, opens Settings, which is standard.

Within views:
- ⌘F (default; `ShortcutAction.findInHistory`) focuses History search.
- ⌘↩ (default; `ShortcutAction.saveReview`) saves the EndSessionSheet; Esc (fixed) closes it.
- Return submits note fields.
- ⌫ deletes the selected History row (with confirm).

---

## 6. Conventions

- **Swift 5 language mode.** Set `SWIFT_STRICT_CONCURRENCY: minimal`. Mark every service and every helper enum that touches SwiftData or AppKit `@MainActor`. Views are main-actor by default. Timer and Notification closures hop to the main actor with `MainActor.assumeIsolated { }` or `Task { @MainActor in }`.
- **SwiftData.**
  - Use `container.mainContext` only; `autosaveEnabled` stays true.
  - Mutating services call `try? context.save()` (the engine uses `save()`) after each user-level action.
  - Insert new objects before linking them.
  - Use `@Query` in views. Never fetch inside `body`.
  - Sort relationship arrays with the `sorted…` helpers.
  - Every edit to a session calls `session.touch()`. Time edits also call `recomputeStoredDuration()`, which SessionEditor does for you.
- **Timers in UI.**
  - Running timers use `TimelineView(.periodic(from: .now, by: 1))` and read `engine.elapsed(at: context.date)`. When paused, render statically.
  - Only `MenuBarLabelView` uses `engine.tick`.
  - Apply `.monospacedDigit()` everywhere a timer appears.
- **Imports.**
  - Add `import SwiftData` wherever models, `@Query` or `ModelContext` appear.
  - Add `import AppKit` for NSImage, NSPanel and the open/save panels.
  - Add `import Charts` for Swift Charts.
  - Add `import AuthenticationServices` for Sign in with Apple.
- **Errors.**
  - No `try!`, no force unwraps of runtime data, and no `fatalError` outside PreviewData and tests.
  - Services expose `lastError: String?`. Views present `.alert` and log with `Log.*`.
  - Throwing APIs (SessionEditor, ExportService) are wrapped in `do`/`catch` in views, showing `error.localizedDescription`.
- **Accessibility.**
  - Every icon-only button needs `.accessibilityLabel` and `.help("…")`.
  - Timers need `.accessibilityLabel("Elapsed time")` plus an `.accessibilityValue` with a spoken duration.
  - Color must never be the only signal; LabelBadge shows the name.
  - Full keyboard navigation in lists and forms.
- **Text.** All UI strings are plain English literals (localization-ready `Text("…")`). Dates use `.formatted` and the Formatting helpers.
- **Sizing.** MenuBarPanelView is 320 wide. OverlayView is 300 wide, or 220 when compact. Sheets have a minimum width of 520.
- **Previews.** Optional. If you add them, use `.withAppServices(.preview)` and `PreviewData`.
- **Tests (CORE).** XCTest, hosted in the app, using `AppServices(inMemory: true)` or an in-memory container. Cover:
  - pause math across midnight
  - split and merge invariants
  - an export → import round trip

---

## 7. Edge cases (MUST handle)

1. **Quit while running.** The session stays in the store with `endedAt == nil` and keeps counting wall time. If `pauseOnQuit` is on, it is paused at quit and `autoPauseReason = .quit`. On relaunch `restoreActiveSession()` adopts it, and A shows a banner.
2. **Sleep and wake.** If `pauseOnSleep` is on, the session auto-pauses at `willSleep`. On wake it stays paused with a Resume banner. All times are wall-clock dates, so no drift is possible.
3. **Forgot to stop.** If the active session's wall time exceeds `longSessionWarningHours`, A shows "Still working?" with options: Stop at last activity (`stop(at: lastActivityDate)`), Stop now, Keep going.
4. **Midnight crossing.**
   - History groups a session by its `startedAt` day.
   - Stats and "today" totals use `activeDuration(in: day.dayInterval)` for sessions and segments.
   - `DateInterval(safeStart:end:)` everywhere prevents traps.
5. **Two Macs or duplicates.** `SeedData.deduplicate` merges seeded label and tag copies with the same uuid, and ends extra active sessions. A session started on Mac A appears as active on Mac B after sync, which is acceptable and documented.
6. **Deleting a label or tag in use.**
   - Settings defaults to Archive.
   - Delete asks for a reassign target or "Unlabeled", via `TaxonomyOps.deleteLabel`.
   - Pickers hide archived items but still display the current selection.
   - `LabelBadge(label: nil)` shows "Unlabeled".
   - Clear `defaultLabelID` when that label is deleted.
7. **Empty states.** Use EmptyStateView for:
   - no sessions (History)
   - no search results
   - no learnings or no tags (Learning)
   - not enough data (Stats: fewer than 1 session in range)
   - no labels (offer "Restore defaults", which calls `SeedData.seedIfNeeded` after resetting the flag)
8. **CloudKit unavailable.** This covers no iCloud account, no entitlement, a load error, or sync disabled. The app uses the `.localOnly` store and shows an info banner and Account status. If the store won't open at all, it runs in-memory: show a persistent error and offer restore from backup. Never delete the store file.
9. **Sign in with Apple not configured.** The error message suggests continuing without signing in. Revoked credentials trigger `signOut()`, which shows WelcomeView; data is untouched.
10. **Very long notes or learnings.** Rows use `lineLimit` with an expand affordance. Use TextEditor for editing. Search is in-memory and fine at this volume. No length limits are enforced, but `overlaySummary` shows a 140-character guidance counter.
11. **Large images.** `AttachmentImporter` downscales to a 2048 px maximum dimension, encodes JPEG at 0.8 (PNG when the source has alpha), and makes a 400 px thumbnail. Grids display only `thumbnailData`, and the full image loads in the viewer.
12. **Stop edge cases.** Stop while paused closes the pause at the stop time. A session under 60 s still opens the EndSessionSheet, which highlights Discard.
13. **Split edge cases.** Live split is allowed while paused. After-the-fact split must be strictly inside the segment, at least `minimumSegmentLength` from each end. Editing times never breaks contiguity, because `normalize` runs.
14. **Import or restore while active.** Replace mode is blocked with a clear error. Merge is allowed. After any import, the engine reconciles via the notification.
15. **Settings with no main window.** Settings is a page of the main window, so `router.showSettings()` selects it and calls `router.showMainWindow()`, which works even after the main window was closed, because the openWindow action was registered at launch (by the menu bar label).
16. **Overlay focus.** The panel is non-activating but can become key, so typing a note doesn't steal app focus. It never hides on deactivate. Its position persists through the frame autosave name.

---

## 8. Configuration files (CORE)

### 8.1 Project generation

`Worklog.xcodeproj` is committed and generated by `scripts/generate_xcodeproj.py` (the XcodeGen `project.yml` of the first rounds is gone). Every build setting lives in the script: bundle ids, team, `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, entitlements per configuration (Debug `Worklog.entitlements`, Release `WorklogRelease.entitlements`), hardened runtime, Swift 5 with minimal concurrency checking, deployment target 14.0. The script walks `Worklog/` and `WorklogTests/`, so new files are picked up when it runs. A setting changed only in Xcode is lost at the next generation.

### 8.2 `Worklog/Resources/Worklog.entitlements`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.app.dabora.worktracker</string></array>
    <key>com.apple.developer.icloud-services</key>
    <array><string>CloudKit</string></array>
    <key>com.apple.developer.aps-environment</key><string>development</string>
    <key>com.apple.developer.applesignin</key>
    <array><string>Default</string></array>
</dict>
</plist>
```
`WorklogRelease.entitlements` adds `com.apple.developer.icloud-container-environment` = Production; its `aps-environment` stays `development` so the Archive build matches Xcode's automatic-signing development profile, and Organizer's Developer ID export rewrites it to `production` from the distribution profile (README *Safe first archive*, step 6 checks it). `WorklogLocal.entitlements` contains only the first three keys. With it, the app runs with "Sign to Run Locally". CloudKit then falls back to the local store, and Sign in with Apple shows its hint.

### 8.3 README (CORE) must explain
1. Open `Worklog.xcodeproj` (or regenerate it with `scripts/generate_xcodeproj.py`; mirror any project-setting change there).
2. Signing: team, the iCloud container `iCloud.app.dabora.worktracker`, Sign in with Apple; Debug vs Release CloudKit environments.
3. Deploy the CloudKit schema to Production before shipping a model change.
4. Run without a team by switching to `WorklogLocal.entitlements`.
5. Data locations:
   - store: `~/Library/Containers/app.dabora.worktracker/Data/Library/Application Support/Worklog/Worklog.store`
   - backups: `…/Worklog/Backups/`; recovered/damaged stores and PreOpen snapshots: `…/Worklog/Recovered/`

---

## 9. Phase plan

- **Phase 2 (parallel).**
  - **CORE:** everything marked CORE.
  - **DES:** `docs/DESIGN.md`, plus everything in `DesignSystem/` and `Shared/`.
  - Each side relies only on the other's API as specified here.
- **Phase 3 (parallel).** A, B and C read this doc plus DESIGN.md and the phase-2 code. They create only files in their own folders and implement the exact root types in §5.3.
- **Phase 4.** The CRITIC checks:
  - signatures against this doc
  - the CloudKit rules in §2
  - §7 edge cases
  - the checklist in §10

---

## 10. Acceptance checklist (requirement → implementation)

| # | Requirement | Implemented in |
|---|---|---|
| 1 | Timer start/pause/resume/stop | `Services/SessionEngine.swift`; UI: `Features/LiveSession/LiveSessionView.swift`, `Features/MenuBar/MenuBarPanelView.swift`, `Features/Overlay/OverlayView.swift`; `App/WorklogCommands.swift` |
| 2 | Label per session from a customizable list | `Models/WorkLabel.swift`, `Shared/LabelPicker.swift`, `Persistence/SeedData.swift`, C: Settings Labels & Tags tab, `Services/TaxonomyOps.swift` |
| 3 | Sub-labels/tags | `Models/WorkTag.swift` (optional parent `label`), `Shared/TagPicker.swift`, C settings tab |
| 4 | Live split into segments | `SessionEngine.split`, A's split popover in LiveSession, MenuBar and Overlay |
| 5 | After-the-fact split and edit of segments (labels/tags/times) | `Services/SessionEditor.swift`, B: `Features/SessionDetail/*` |
| 6 | Live timestamped notes | `SessionEngine.addNote`, `Models/Note.swift`, A note composer, `Shared/NoteRow.swift` |
| 7 | Menu bar extra quick access (controls, note, split, label, takeaway) | `App/WorklogApp.swift`, A: `MenuBarPanelView`, `MenuBarLabelView`; `SessionEngine.lastTakeaway` |
| 8 | Floating overlay (NSPanel) with configurable content | `Services/OverlayPanelController.swift`, A: `OverlayView`, `AppSettings` overlay keys, C: Overlay tab |
| 9 | End-of-session sheet (title, label/tags, learnings) | A: `EndSessionSheet`, B: `LearningsEditor`, `SessionEngine.pendingEndSession/completeReview`, `App/RootView.swift` |
| 10 | History sortable by date/label/length | B: `HistoryView` + `HistorySort`, `WorkSession.storedActiveDuration` |
| 11 | Search across notes, titles, labels, tags, learnings | `Services/SearchService.swift`, B: HistoryView search |
| 12 | Session detail: notes, date, title, images, segments; edit after the fact | B: `SessionDetailView` + sections, `SessionEditor`, `AttachmentImporter` |
| 13 | Images attached (picker, paste, drop), downscaled, synced | `Models/Attachment.swift` (`.externalStorage`), `Services/AttachmentImporter.swift`, B attachments section |
| 14 | Learnings text + overlay summary + show-in-overlay | `WorkSession.learningText/overlaySummary/showInOverlay`, B `LearningsEditor`, `SessionEngine.refreshTakeaway`, A overlay and menu |
| 15 | Tagged learning points + Learning evolution page | `Models/LearningPoint.swift`, B `LearningsEditor`, C: `Features/Learning/LearningView.swift` |
| 16 | Stats with Swift Charts | C: `Features/Stats/StatsView.swift`, `StatsCalculator.swift` |
| 17 | Themes (3, extensible), appearance, accent | `DesignSystem/*` (ThemeID, Theme.make, ThemeManager), C: Appearance tab |
| 18 | Account: Sign in with Apple, sign out, continue without | `Services/AuthService.swift`, `Services/KeychainStore.swift`, C: `WelcomeView`, Account tab; RootView gate |
| 19 | Overlay customization | `AppSettings` overlay keys, C: Overlay tab, `OverlayPanelController` observation |
| 20 | Export JSON + CSV; import | `Services/ExportService.swift`, `Services/ExportDTOs.swift`, C: Data tab |
| 21 | Manage labels and tags | `Services/TaxonomyOps.swift`, `Shared/LabelColorPicker.swift`, `Shared/SymbolPicker.swift`, C: Labels & Tags tab |
| 22 | iCloud sync + local fallback | `Persistence/PersistenceController.swift`, entitlements, models follow CloudKit rules |
| 23 | Rolling local JSON backups + restore | `Services/BackupService.swift`, `App/AppDelegate.swift` (on quit), C: Data tab |
| 24 | Running session survives relaunch | `SessionEngine.restoreActiveSession` (`endedAt == nil` + `pauseIntervals`), AppDelegate |
| 25 | Project, entitlements, identifiers | `scripts/generate_xcodeproj.py`, `Worklog.xcodeproj`, `Worklog/Resources/*.entitlements`, `README.md`, `AppConstants` |
| 26 | Keyboard shortcuts | `App/WorklogCommands.swift`, `WindowRouter` requests, A observers |
| 27 | Edge cases §7 | engine (1–3, 12), Formatting/models (4), SeedData (5), TaxonomyOps + C (6), all features (7), Persistence + RootView (8), Auth (9), AttachmentImporter (11), SessionEditor (13), ExportService (14), WindowRouter (15), OverlayPanelController (16) |

### Critical files for implementation
- /home/user/work-tracker/docs/ARCHITECTURE.md (this document; the contract every agent follows)
- /home/user/work-tracker/Worklog/Models/WorkSession.swift (core model, duration math and invariants)
- /home/user/work-tracker/Worklog/Services/SessionEngine.swift (live session state machine shared by window, menu bar and overlay)
- /home/user/work-tracker/Worklog/App/AppServices.swift (service graph + `withAppServices` injection used by every scene)
- /home/user/work-tracker/Worklog/DesignSystem/Theme.swift (Theme API every view depends on)

---

## 11. Round 2

Round 2 adds in-app Settings, customizable shortcuts and an editable overlay layout, and fixes the History layout bug. The engine/app side (CORE, "ENG") is summarised here. The design side is in `docs/DESIGN.md` §7–§12.

### 11.1 `Services/OverlayLayout.swift`

> Superseded in round 4: the overlay layout is a grid (`OverlayGridLayout`), see §13.2. `OverlayElement` below is unchanged.

```swift
/// One element of the floating overlay. Persisted by rawValue in `AppSettings.overlayLayout`.
enum OverlayElement: String, CaseIterable, Identifiable, Codable, Hashable {
    case label, timer, segmentFocus, controls, split, todayTotal, note, takeaway
    var id: String { rawValue }
    var title: String { get }          // "Label", "Timer", "Segment focus", "Controls", "Split", "Today’s total", "Quick note", "Takeaway"
    var systemImage: String { get }    // "tag", "timer", "scope", "playpause", "scissors", "target", "square.and.pencil", "quote.opening"
    /// Fresh install and "Reset layout": [.label, .timer, .segmentFocus, .controls, .split, .note, .takeaway]
    static let defaultLayout: [OverlayElement]
    /// Legacy migration order: [.label, .timer, .segmentFocus, .controls, .split, .todayTotal, .note, .takeaway]
    static let migrationOrder: [OverlayElement]
    /// Drops unknown raw values and duplicates (first occurrence wins), keeps order.
    static func sanitized(_ rawValues: [String]) -> [OverlayElement]
}
```

### 11.2 `AppSettings` overlay changes

> Superseded in round 4: `overlayGrid` is the source of truth and `overlayLayout` is a compatibility accessor, see §13.3. The legacy-boolean migration below still applies.

- **Removed:** `overlayShowTimer`, `overlayShowLabel`, `overlayShowSegmentFocus`, `overlayShowControls`, `overlayShowSplitButton`, `overlayShowNoteField`, `overlayShowLastTakeaway`, `overlayShowTodayTotal`.
- **Kept:** `overlayEnabled`, `overlayCompact`, `overlayOpacity`, `overlayAlwaysOnTop`, `overlayShowOnAllSpaces`, `overlayHideWhenIdle`.
- **Added:** `var overlayLayout: [OverlayElement]` (key `settings.overlayLayout`, `[String]` raw values), `func overlayShows(_:) -> Bool`, `func resetOverlayLayout()`. An empty layout is valid (the overlay shows only its header).
- **Migration** (in `init`, once): a stored `settings.overlayLayout` array is sanitized and used. Otherwise the layout is built from `migrationOrder`, keeping each element whose legacy key (`settings.overlayShowLabel`, `…Timer`, `…SegmentFocus`, `…Controls`, `…SplitButton`, `…TodayTotal`, `…NoteField`, `…LastTakeaway`) is true; an absent key counts as its old default (all on except Today’s total). The result is written immediately, so later changes to the legacy keys have no effect. The legacy keys themselves are left untouched (downgrade-safe). With default legacy values the result is exactly `defaultLayout`.
- **`resetOverlayDefaults()`** sets `overlayLayout = .defaultLayout`, `overlayCompact = false`, `overlayOpacity = 0.95`, `overlayAlwaysOnTop = true`, `overlayShowOnAllSpaces = true`, `overlayHideWhenIdle = false`. `overlayEnabled` is unchanged.

### 11.3 `Services/ShortcutStore.swift`

```swift
enum ShortcutGroup: String, CaseIterable, Identifiable { case session, navigation, editing; var title: String { get } }

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case startStop, pauseResume, addNote, splitSegment, discardSession, toggleOverlay   // .session
    case showToday, showHistory, showLearning, showStats, nextProfile                 // .navigation (nextProfile: round 3, no default)
    case findInHistory, saveReview                                                    // .editing (in-view)
    var title: String { get }                    // also the Settings ▸ Shortcuts row title
    var group: ShortcutGroup { get }
    var defaultShortcut: StoredShortcut? { get } // ⇧⌘S ⇧⌘P ⇧⌘N ⇧⌘D – ⇧⌘O ⌘1 ⌘2 ⌘3 ⌘4 ⌘F ⌘↩
}

struct StoredShortcut: Codable, Hashable {
    var key: String        // one lowercase character, or a token ("return", "escape", "delete", "deleteForward", "tab",
                           // "space", "upArrow", "downArrow", "leftArrow", "rightArrow", "home", "end", "pageUp", "pageDown")
    var modifiers: Int     // EventModifiers.rawValue, limited to ⌃⌥⇧⌘
    init(key: String, modifiers: EventModifiers)   // lowercases single characters, drops other modifiers
    static let none: StoredShortcut                // key "" = explicitly no shortcut
    var isNone: Bool { get }
    var eventModifiers: EventModifiers { get }
    var keyboardShortcut: KeyboardShortcut? { get } // nil for .none or an invalid key
    var displayString: String { get }               // "⌃⌥⇧⌘S" order; "" for .none
    init?(event: NSEvent)                           // keyDown only; nil for F-keys, keypad-only keys, empty
}

enum ShortcutValidation: Equatable {
    case ok, needsModifier, reserved, shiftNeedsLetter, conflict(ShortcutAction)
    var message: String? { get }   // nil, "Include ⌘ or ⌃.", "Reserved by macOS.", "Use ⇧ with a letter.", "Used by <title>."
}

@MainActor @Observable
final class ShortcutStore {
    init(defaults: UserDefaults = .standard)
    func stored(for action: ShortcutAction) -> StoredShortcut?        // override (nil if .none) else default
    func shortcut(for action: ShortcutAction) -> KeyboardShortcut?    // for `.keyboardShortcut(_:)` (optional overload)
    func displayString(for action: ShortcutAction) -> String?         // nil when unassigned
    func isDefault(_ action: ShortcutAction) -> Bool
    var hasCustomizations: Bool { get }
    func validate(_ shortcut: StoredShortcut, for action: ShortcutAction) -> ShortcutValidation
    @discardableResult func set(_ shortcut: StoredShortcut?, for action: ShortcutAction) -> ShortcutValidation
    @discardableResult func reset(_ action: ShortcutAction) -> ShortcutAction?   // the action that lost its shortcut
    func resetAll()
    static let reservedShortcuts: [StoredShortcut]   // ⌘, ⌘Q ⌘W ⌥⌘W ⌘H ⌥⌘H ⌘M ⌥⌘M ⌃⌘F ⌃⌘S ⌘` ⌃⌘Q ⌃⌘Space ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A ⇧⌘/
}
```

- **Validation order:** the modifiers must include ⌘ or ⌃ (`.needsModifier`), the combo must not be reserved (`.reserved`), ⇧ may only go with a letter or a special key such as ↩ or an arrow (`.shiftNeedsLetter`; menus match ⇧⌘1 or ⇧⌘= by the shifted character, so they may never fire), and it must not equal another action's effective shortcut (`.conflict(other)`). Re-assigning an action its current shortcut is `.ok`.
- **`set`:** `nil` or `StoredShortcut.none` clears (always `.ok`). Anything else is validated and written only on `.ok`. A value equal to the default removes the override. Note that in a `StoredShortcut?` context a bare `.none` means `nil`; both clear.
- **`reset`:** removes the override. If another action has since taken that default, that other action is cleared, so no two actions ever share a shortcut. Returns that other action (nil if none) so Settings ▸ Shortcuts can say "Removed from <title>."
- **Persistence:** UserDefaults key `shortcuts.overrides` holds JSON `[String: StoredShortcut]` keyed by `ShortcutAction.rawValue`. Only overrides are stored; a cleared action with a default stores `StoredShortcut.none` (clearing Discard Session, which has no default, is the default state). Unknown keys and undecodable data are ignored. Loading resolves duplicates in `allCases` order: an action whose effective shortcut equals an earlier action's is cleared. With no overrides the key is removed.
- **Plumbing:** `AppServices.shortcuts` is created right after `settings` with the same `defaults` (the ephemeral suite when `inMemory`). `withAppServices` adds `.environment(services.shortcuts)`, so the main window, the MenuBarExtra (panel and label) and the overlay panel all have it, and sheets/popovers inherit it. Views read it with `@Environment(ShortcutStore.self) private var shortcuts`.
- **Users:** `WorklogCommands` (every Session and View menu item through a private `ShortcutCommandButton` View), HistoryView (⌘F, `.findInHistory`), EndSessionSheet (Save, `.saveReview`), the menu bar panel's overlay hint (`displayString(for: .toggleOverlay)`) and Settings ▸ Shortcuts.
- **Fixed, not customizable:** ⌘, Settings; ⌘Q, ⌘H, ⌘W, ⌥⌘W, ⌘M, ⌥⌘M, full screen, ⌃⌘Space Emoji & Symbols, ⌃⌘S Toggle Sidebar; the Edit menu; `.defaultAction`/`.cancelAction` in sheets and popovers; Return in text fields; ⌫ in the History list; ←/→ in the image viewer.

### 11.4 In-app Settings and navigation

- `SidebarItem` gains `.settings` ("Settings", `gearshape`) and `static let primaryItems` (the four List rows).
- There is no `Settings` scene. `WorklogCommands` replaces `.appSettings` with "Settings…" (⌘, fixed) → `router.showSettings()`.
- `WindowRouter.showSettings()` is `selection = .settings; showMainWindow()` (it reopens a closed main window). `showSettings(tab:)` sets `settingsTabRequest` first. `register(openWindow:openSettings:)` ignores `openSettings` (deprecated). There is no `OpenSettingsAction` storage, and no view uses `SettingsLink` or `@Environment(\.openSettings)`.
- `RootView` shows `SettingsView()` for `.settings`; the footer gear selects it and is highlighted while it is shown (§5.2). The account name opens Settings ▸ Account.
- While `auth.needsWelcome`, Settings requests show Settings full-window over Welcome, with a "Back" button (§5.2).

### 11.5 Window sizing (History layout fix)

- The main `Window` uses `.windowResizability(.contentMinSize)` with the root's `.frame(minWidth: 900, minHeight: 600)` and `.defaultSize(1100, 720)`. With `.contentMinSize` the window's minimum follows the content's, so it stays 900 × 600 only because of the 0-minimum barriers below.
- RootView's detail column is a min-size barrier (explicit `minWidth: 0`/`minHeight: 0` frames + `.clipped()`), and the sidebar's mini status row and footer are pinned with `.safeAreaInset(edge: .bottom)`.
- Feature side (F1): `HistoryView` no longer nests an `HSplitView` inside the `NavigationSplitView`; it uses an `HStack` with a fixed, user-draggable list width (`history.listWidth`, 280–460, default 340) and a zero-minimum detail.

### 11.6 Copy

User-facing strings follow the copy guideline in `docs/DESIGN.md` §12.0 (short action-name tooltips, ≤ 1-sentence helper text and errors, no hard-coded shortcut glyphs). On the CORE side this covers the RootView banners and footer, the recovery launch notices in `AppServices`, the engine's handoff notices and the error messages of `SessionEditError`, `DataTransferError`, `AttachmentImportError`, `AuthService`, `BackupService` and `SyncMonitor`.

## 12. Round 3: Profiles

Round 3 adds profiles ("Work", "Personal", …): independent sessions, labels/tags that are global or local to one profile, per-profile stats/takeaways/default label, a drop-up switcher above the sidebar footer and a quick-start profile for the menu bar and overlay. The engine/app side (ENGINE) is summarised here; the UI is in `docs/DESIGN.md` §16.

### 12.1 Decisions

| Topic | Decision |
|---|---|
| Default profile | **"Work"**, `briefcase.fill`, `#5B8DEF`, fixed uuid `6F1C0E10-0000-4000-8000-000000000201`, sortIndex 0. |
| Existing labels and tags | Become **global** (`profile == nil`); nothing is written. The fixed-uuid seeded defaults stay global, so two Macs converge. |
| New labels/tags created by the user | Local to the current profile (Settings can change the scope). |
| Existing sessions | Assigned to the default profile once. `profile == nil` = unassigned (legacy, an older app version on another Mac, or the profile was deleted remotely); **repaired** into the *home profile* every time `SeedData.deduplicate` runs. Never touches `modifiedAt`. |
| Making a label/tag local while other profiles use it | After a confirm, **each other profile gets its own copy** (a same-name item offered there, else a new local copy); their sessions are re-pointed. Nothing becomes unlabeled. |
| Moving a session | Labels/tags the target doesn't offer are mapped to a same-name one offered there, else **copied** in as locals. |
| Invariant | A session (its segments and learning points) only references labels/tags **offered** in its profile (global + local to it). |
| Filtering | In memory with `ProfileScope`. **No `#Predicate` on relationship key paths** (optional to-one chains had runtime problems on macOS 14.0–14.3 with CloudKit stores; `@Query` can't be re-parameterized without rebuilding the view). |
| Active profile | Per device (`UserDefaults "profiles.activeProfileID"`), resolved with a fallback that is never written back. |
| Quick start | `AppSettings.quickStartProfileID` (nil = current profile), used by the menu bar and overlay. ⇧⌘S and Today's Start always use the **current** profile. |
| Default label | Per profile: `WorkProfile.defaultLabelUUID` (syncs). The legacy `settings.defaultLabelID` is copied into the default profile once. |
| Takeaway | Per profile (`SessionEngine.takeaways`). |
| Running session on switch | Keeps running in its own profile. |
| Next-profile shortcut | `ShortcutAction.nextProfile` ("Switch to Next Profile"), navigation group, no default. |
| Export | `formatVersion` 2; new fields optional, so v1 archives decode (sessions → home profile, labels/tags global). |

### 12.2 Data model

`Models/WorkProfile.swift`:
```swift
@Model final class WorkProfile {
    var uuid: UUID = UUID()
    var instanceID: UUID = UUID()          // new on every insert; dedupe tie-break
    var name: String = ""
    var colorHex: String = "#5B8DEF"
    var symbolName: String = "briefcase.fill"
    var sortIndex: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var defaultLabelUUID: UUID? = nil      // nil = first offered label
    var sessions: [WorkSession]? = []
    var labels: [WorkLabel]? = []          // local labels
    var tags: [WorkTag]? = []              // local tags
    init(name: String, colorHex: String = "#5B8DEF", symbolName: String = "briefcase.fill",
         sortIndex: Int = 0, uuid: UUID = UUID())
}
extension WorkProfile { var displayName: String; var sessionCount: Int; func touch() }
```
Additive to-one relationships (inverse declared on the to-one side, nullify, optional, no default):
`WorkSession.profile` (inverse `\WorkProfile.sessions`), `WorkLabel.profile` (`\WorkProfile.labels`, nil = global), `WorkTag.profile` (`\WorkProfile.tags`, nil = global). Helpers `WorkLabel.isGlobal`, `WorkTag.isGlobal`.

**CloudKit:** every attribute has a default, relationships are optional with one declared inverse, no `.unique`. It is additive only (a new entity plus three to-one columns), so automatic lightweight migration handles local and CloudKit stores. The dev schema gains `CD_WorkProfile` and a `CD_profile` field on `CD_WorkSession`, `CD_WorkLabel` and `CD_WorkTag` — **deploy the dev schema to Production before release**. `WorkProfile.self` is in `WorklogSchemaV1.models` (live types, version stays 1.0.0; no V2 with the same types — duplicate checksum).

### 12.3 Migration, repair and dedupe

```swift
// SeedData
static let provisionalDefaultProfileKey = "profiles.provisionalDefaultInstanceID"
static let legacyDefaultLabelCopiedKey = "profiles.legacyDefaultLabelCopied"
static var isSessionProfileRepairDisplayOnly: Bool  // AppServices: = persistence.isSyncingWithICloud (default false)
@discardableResult static func repairSessionProfilesIfAllowed(in context: ModelContext) -> Int  // the ONE repair entry
static func ensureProfiles(in context: ModelContext, settings: AppSettings, provisional: Bool = false)
static func discardProvisionalDefaultProfile(in context: ModelContext, defaults: UserDefaults = .standard)
```
- **Unassigned sessions** (profile nil or deleted): shown everywhere in their *effective profile* (`ProfileOps.effectiveProfile(of:)`: the single non-archived profile owning the local labels/tags the session uses, else `homeProfile`). In CloudKit mode nothing is written in the background (a write could overwrite a profile relationship another Mac hasn't finished syncing); the relationship is written only when the user edits that session: every `SessionEditor` edit (`finish`), `moveSession`, and the engine's stop / completeReview / resumePendingSession / split / updateCurrentSegment / addNote call `ProfileOps.assignProfileIfUnassigned` (effective profile + `TaxonomyOps.conformTaxonomy`, no touch). A local-only store keeps the background repair. Every background call goes through `repairSessionProfilesIfAllowed` (no-op in CloudKit mode): `ensureProfiles`, `deduplicate`, `TaxonomyOps.setScope`, import and delete-all.
- `ensureProfiles`: no profile → `ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: settings.defaultLabelID)`; if `provisional`, the new profile's instanceID is stored under the key (in `settings.defaults`). Once (`legacyDefaultLabelCopiedKey`): an existing default-uuid profile without a default label gets the legacy `settings.defaultLabelID`. Then `repairSessionProfilesIfAllowed`; saves if anything changed.
- `discardProvisionalDefaultProfile`: after the first iCloud import, the stored profile is deleted when it still exists, has no sessions and no local labels/tags, and another non-archived profile exists (the user deleted "Work" elsewhere). The key is always cleared once evaluated.
- `deduplicate(in:)`: profiles → labels → tags → sessions → `repairSessionProfilesIfAllowed` → save if changed. Profiles use the label rules for the surviving row (`taxonomyPrecedes`: oldest createdAt, then instanceID; a tie deletes nothing), but take the attributes (name, colorHex, symbolName, sortIndex, isArchived, defaultLabelUUID when set, modifiedAt) of the most recently modified copy (`sessionPrecedes` order); a duplicate's sessions, labels and tags move to the survivor, its `defaultLabelUUID` is copied when the survivor still has none, and `ensureNonArchivedProfile` runs afterwards. `ensureDefaultProfile` stamps `modifiedAt` = 1970 so a freshly created default copy never wins that attribute merge. Label/tag copies scoped differently (other profile or global) make the survivor global.

`Services/ProfileOps.swift`:
```swift
enum ProfileDeletion: Equatable { case moveSessions(toProfileID: UUID), deleteSessions }
enum ProfileOpResult: Equatable {
    case ok, lastProfile, sessionRunning, invalidTarget
    var message: String? { get }   // nil, "Keep at least one profile.", "Stop the session first.", "Choose another profile."
}
@MainActor enum ProfileOps {
    nonisolated static let defaultProfileUUID: UUID           // 6F1C0E10-…-000000000201, UUID(uuid:) bytes
    nonisolated static let defaultProfileName = "Work", defaultProfileColorHex = "#5B8DEF", defaultProfileSymbol = "briefcase.fill"
    static func allProfiles(in:) -> [WorkProfile]             // live, archived included, (sortIndex, createdAt, uuidString)
    static func profile(withID: UUID?, in:) -> WorkProfile?
    static func homeProfile(in:) -> WorkProfile?              // default uuid if active, else first active, else first
    @discardableResult static func ensureDefaultProfile(legacyDefaultLabelID: UUID?, in:) -> WorkProfile?  // no save
    @discardableResult static func repairSessionProfiles(in:) -> Int   // no save; call via SeedData.repairSessionProfilesIfAllowed
    @discardableResult static func ensureNonArchivedProfile(in:) -> Bool   // all archived → unarchive the first; no save
    static func effectiveProfile(of: WorkSession) -> WorkProfile?    // display-only; cached home (2 s)
    static func effectiveProfileID(of: WorkSession) -> UUID?
    static func isUnassigned(_: WorkSession) -> Bool
    @discardableResult static func assignProfileIfUnassigned(_: WorkSession, in:) -> WorkProfile?  // user edits; no save
    static func invalidateHomeProfileCache()
    @discardableResult static func createProfile(name:colorHex:symbolName:in:) -> WorkProfile             // saves
    static func reorder(_ profiles: [WorkProfile])
    @discardableResult static func setArchived(_:_:settings:in:) -> ProfileOpResult
    @discardableResult static func delete(_:_:settings:in:) -> ProfileOpResult
}
```
- `setArchived`: archiving the last non-archived profile → `.lastProfile`; archiving a profile with a running session → `.sessionRunning`; clears `settings.quickStartProfileID` if it pointed there.
- `delete`: `.lastProfile` when no other non-archived profile would remain. `.moveSessions`: the target must be live, non-archived and another profile (else `.invalidTarget`); sessions and the profile's local labels/tags move to it (they stay local, now to the target), except a non-archived local whose name the target already offers (non-archived) is merged into that one (`TaxonomyOps.absorb`); unassigned sessions whose effective profile was this one move to the target too. (`.deleteSessions` leaves unassigned sessions alone: they show in the next home profile. The Settings sheet makes a manual backup before deleting sessions.) `.deleteSessions`: `.sessionRunning` while one of its sessions has `endedAt == nil`; otherwise its sessions are deleted (cascade), its local labels/tags still used by a session outside the profile become global, the rest are deleted. Both clear `quickStartProfileID` if it pointed there, delete the profile and save.

Scenarios: two Macs upgrading both create the fixed-uuid "Work" — dedupe keeps the oldest and re-points everything. A new Mac with CloudKit creates a *provisional* "Work" at launch (the UI always has a profile); after the first import dedupe merges it into the synced copy, or `discardProvisionalDefaultProfile` removes it when the user had deleted "Work". Sessions from un-upgraded Macs arrive unassigned: shown in their effective profile (written on edit; repaired in local-only stores). A profile deleted remotely: its sessions become unassigned the same way, its local labels/tags become global.

### 12.4 Scope rules

| Surface | Session scope | Labels/tags offered |
|---|---|---|
| Today idle (start form, today total, today's sessions, takeaway) | current profile | current profile |
| Today active (timer, segment form, today total, notes) | the running session's profile (ProfileBadge with 2+ profiles) | session's profile |
| End-of-session sheet, Session detail | n/a | the session's effective profile (`ProfileOps.effectiveProfile(of:)`) |
| History (list, search, chips, "Live session" row only if in scope) | current profile | current profile |
| Learning | current profile | n/a |
| Stats | current profile, or "All profiles" (+ "By profile" chart) | n/a |
| Settings ▸ Labels & Tags | n/a | current profile, with a scope control per item |
| Menu bar panel and overlay | the *panel profile*: running session's profile when active, else `profiles.quickStartProfile` | panel profile |
| ⇧⌘S and Today Start | current profile | current profile |
| Export, backup, CSV | everything (CSV gets a `profile` column) | n/a |

Delete/merge targets: a global source may only go to global targets; a source local to P to global targets or P's locals (`TaxonomyOps.reassignmentTargets` / `mergeTargets`).

### 12.5 `ProfileScope` and `ProfileStore` (`Services/ProfileStore.swift`)

```swift
struct ProfileScope: Hashable, Sendable {
    let profileID: UUID?                       // nil = all profiles (or a store with no profile: graceful degrade)
    init(profileID: UUID?)
    static let allProfiles: ProfileScope
    var isAllProfiles: Bool { get }
    @MainActor func contains(_ session: WorkSession) -> Bool   // live session whose EFFECTIVE profile uuid == profileID
    @MainActor func contains(_ point: LearningPoint) -> Bool   // its live session is contained
    @MainActor func offers(_ label: WorkLabel) -> Bool         // live and global (nil/deleted profile) or local to profileID
    @MainActor func offers(_ tag: WorkTag) -> Bool
    @MainActor func filter(_ sessions: [WorkSession]) -> [WorkSession]
}

@MainActor @Observable final class ProfileStore {
    static let activeProfileKey = "profiles.activeProfileID"   // in settings.defaults
    private(set) var profiles: [WorkProfile]            // live, non-archived, sorted
    private(set) var archivedProfiles: [WorkProfile]
    private(set) var activeProfile: WorkProfile?        // stored id if live & active, else profiles.first (not written back)
    private(set) var activeProfileID: UUID?
    var activeScope: ProfileScope { get }
    var hasMultipleProfiles: Bool { get }
    var quickStartProfile: WorkProfile? { get }         // settings.quickStartProfileID among `profiles`, else activeProfile
    var quickStartProfileID: UUID? { get }
    init(context: ModelContext, settings: AppSettings)  // loads immediately
    func reload()                                       // assigns only on change
    func startObserving()                               // didSave (200 ms), .worklogDataDidImport, remote change (1.5 s)
    func select(_ profile: WorkProfile)                 // ignores archived/deleted; persists
    func select(id: UUID)
    func selectNext()                                   // wraps; no-op with < 2
    func profile(withID id: UUID?) -> WorkProfile?      // among the loaded lists (no fetch; safe in body)
    @discardableResult func createProfile(name:colorHex:symbolName:select:) -> WorkProfile
    @discardableResult func setArchived(_:_:) -> ProfileOpResult   // archiving the current selects the fallback
    @discardableResult func delete(_:_:) -> ProfileOpResult        // current → move target / fallback; .deleteSessions posts .worklogDataDidImport
    func reorder(_ ordered: [WorkProfile])
}
```

**`@Query` pattern, everyone.** Keep `@Query` unfiltered by profile (or filtered on plain attributes); read `@Environment(ProfileStore.self) private var profiles` and filter in memory with `profiles.activeScope.filter(_:)`, `.contains(_:)`, `.offers(_:)`, or `ProfileScope(profileID: ProfileOps.effectiveProfileID(of: session))` for a session's own profile (never `session.profile` directly: an unassigned session has none but is shown in its effective profile). Never write `#Predicate { $0.profile?.uuid == id }`. Never read `x.profile.name` on a possibly deleted model; use `ModelLiveness.live(x.profile)`.

### 12.6 Service changes

**`SessionEngine`**
```swift
init(context: ModelContext, settings: AppSettings, profiles: ProfileStore? = nil)
var activeSessionProfile: WorkProfile? { get }      // live profile of the active session
var activeSessionProfileID: UUID? { get }
var contextProfileID: UUID? { get }                 // active session's profile when active, else profiles?.activeProfileID
private(set) var takeaways: [UUID?: SessionTakeaway] // per effective profile uuid (nil = no profile at all)
var lastTakeaway: SessionTakeaway? { get }          // COMPUTED: takeaways[contextProfileID]
func takeaway(for profileID: UUID?) -> SessionTakeaway?
func dismissTakeaway(_ takeaway: SessionTakeaway? = nil)   // nil → lastTakeaway; retires within its profile only
func defaultLabel(for profile: WorkProfile? = nil) -> WorkLabel?
@discardableResult func start(label: WorkLabel?, tags: [WorkTag] = [], focus: String = "", at date: Date = .now,
                              profile: WorkProfile? = nil) -> WorkSession
func totalActiveToday(now: Date = .now, scope: ProfileScope = .allProfiles) -> TimeInterval
```
- `SessionTakeaway` gains `var profileID: UUID? = nil` (last).
- `defaultLabel(for:)`: profile nil → current profile. Candidates are the non-archived labels offered there, by sortIndex; preference `profile.defaultLabelUUID` (legacy `settings.defaultLabelID` only when there is no profile at all); else the first.
- `start`: profile nil → the current profile (live, non-archived) else nil. A label not offered there is replaced by `defaultLabel(for:)`; tags not offered are dropped.
- `refreshTakeaway()` fetches up to 200 candidates; the newest per profile wins. `retireTakeaways(through:)` only retires sessions of the source's profile.

**`SessionEditor`**
```swift
static func moveSession(_ session: WorkSession, to profile: WorkProfile, in context: ModelContext)
static func taxonomyCopiedByMove(of session: WorkSession, to profile: WorkProfile) -> [String]
```
`moveSession` re-points the session (ended or running) and calls `TaxonomyOps.conformTaxonomy` (every label/tag of the session, its segments and learning points that the target doesn't offer → `equivalentLabel/Tag`, one per source item, no duplicates); touch + save; no-op when already there. `taxonomyCopiedByMove` lists the names that would be *copied* (no same-name equivalent), sorted, unique.

**`TaxonomyOps`**
```swift
enum TaxonomyScopeImpact: Equatable { case none; case copiesForOtherProfiles(profileNames: [String], sessionCount: Int) }
static func createLabel(name:colorHex:symbolName:profile: WorkProfile? = nil, in:) -> WorkLabel
static func createTag(name:colorHex: = "#8E8E93", label: = nil, profile: WorkProfile? = nil, in:) -> WorkTag
static func scopeChangeImpact(of: WorkLabel, to: WorkProfile?) -> TaxonomyScopeImpact
static func scopeChangeImpact(of: WorkTag, to: WorkProfile?) -> TaxonomyScopeImpact
static func setScope(of: WorkLabel, to: WorkProfile?, in:)
static func setScope(of: WorkTag, to: WorkProfile?, in:)
static func equivalentLabel(for: WorkLabel, in profile: WorkProfile, in:) -> WorkLabel   // may insert; no save
static func equivalentTag(for: WorkTag, in profile: WorkProfile, in:) -> WorkTag
static func existingEquivalentLabel(for:in:in:) -> WorkLabel?   // same lookup, never inserts
static func existingEquivalentTag(for:in:in:) -> WorkTag?
@discardableResult static func conformTaxonomy(of: WorkSession, to: WorkProfile, in:) -> Bool  // no touch, no save
static func localDuplicatesMerged(byMakingGlobal: WorkLabel, in:) -> [WorkLabel]   // for confirm texts
static func localDuplicatesMerged(byMakingGlobal: WorkTag, in:) -> [WorkTag]
static func absorb(_: WorkLabel, into: WorkLabel, in:)   // merge without settings; no save
static func absorb(_: WorkTag, into: WorkTag, in:)
static func reassignmentTargets(for: WorkLabel, among: [WorkLabel]) -> [WorkLabel]
static func mergeTargets(for: WorkTag, among: [WorkTag]) -> [WorkTag]
```
- `createTag` returns an existing non-archived same-name tag offered in `profile` (the profile's own one first; with `profile` nil only global tags count), else a new tag local to `profile`.
- `setScope` to a profile: `repairSessionProfilesIfAllowed`, then `item.profile = profile` (a label: global tags and other profiles' tags whose parent it is lose that parent), then every other (effective) profile Q whose sessions/segments (tags: also learning points) use it is re-pointed to `equivalent…(for:in: Q)`; a `Q.defaultLabelUUID` pointing to the label follows to Q's copy. To nil (from local): a non-archived item absorbs the non-archived same-name items local to any profile (`localDuplicatesMerged`); a tag also drops a local parent label. Saves.
- `equivalent…`: same name (trimmed, case/diacritic-insensitive, non-archived preferred) offered in the profile, excluding the item itself when it isn't offered there; else a local copy (name, color, symbol, sortIndex, archived state; tag copies keep the parent label only if it is offered there).
- `deleteLabel` clears every profile's `defaultLabelUUID` pointing to it; `mergeLabel` points them to the target.

**`SearchService`**: `@MainActor static func filter(_ sessions: [WorkSession], query: String, scope: ProfileScope) -> [WorkSession]` (scope first, then the query).

**Export (`ExportDTOs`, `ExportService`)**
- `ExportArchive.currentFormatVersion = 2`; `var profiles: [ProfileDTO]? = nil` (v2 always writes it, possibly `[]`). `ProfileDTO { id, name, colorHex, symbolName, sortIndex, isArchived, createdAt, modifiedAt, defaultLabelID }`. `LabelDTO`, `TagDTO`, `SessionDTO` append `var profileID: UUID? = nil` (synthesized Decodable uses decodeIfPresent → v1 decodes). Format 3+ is rejected.
- `ImportSummary.profiles` (archive profiles); the description adds ", N profile(s)" only when > 0.
- Import order profiles → labels → tags → sessions. Profiles: upsert by uuid, existing ones untouched. New labels/tags get the archived scope; in merge mode existing ones keep theirs, in replace mode the archived scope is set. Sessions: archived profile ?? local profile ?? home (`homeProfile`, or `ensureDefaultProfile` when none exists), then `TaxonomyOps.conformTaxonomy` (labels/tags the profile doesn't offer are mapped or copied). Replace also ensures the default profile; both modes then `ensureNonArchivedProfile` and `repairSessionProfilesIfAllowed` before saving.
- `deleteEverything()` deletes profiles too; `deleteAllData()` then recreates the default profile.
- CSV: a trailing `profile` column (effective profile name, "" if none) on both files.

**`AppSettings`**: `var quickStartProfileID: UUID?` (key `settings.quickStartProfileID`, uuidString, nil = current profile; assigned last in `init`). `defaultLabelID` is legacy: read once by the migration, no longer written by the UI.

**`ShortcutStore`**: `.nextProfile` ("Switch to Next Profile", `.navigation`, no default).

### 12.7 Plumbing

- **AppServices order:** settings → shortcuts → persistence → sync → themeManager → auth → router → **profiles** → engine(…, profiles:) → exporter → backups → overlay.
- **Data setup:** the existing branches, then `SeedData.ensureProfiles` in each (inMemory after `PreviewData.populate`; recovery after `insertDefaults`; normal after restore/seed with `provisional = isSyncingWithICloud && !sync.hasCompletedFirstImport` — only effective when no profile existed), then `deduplicate`, `profiles.reload()`, `router.profiles = profiles`, `engine.restoreActiveSession()`, `profiles.startObserving()`.
- **Repair gate:** right after `persistence`, `SeedData.isSessionProfileRepairDisplayOnly = persistence.isSyncingWithICloud`.
- **Provisional follow-up:** when the key is set (now or from an earlier launch) and the store is CloudKit, a Task waits for `sync.hasCompletedFirstImport` (polls every 2 s, gives up after 10 min without doing anything — the key stays for the next launch); once it completed: `deduplicate` → `discardProvisionalDefaultProfile` → `profiles.reload()`. The deferred-seeding Task also reloads the profiles.
- **CloudKit schema (DEBUG):** launch argument `-initializeCloudKitSchema` → `PersistenceController.initializeCloudKitSchemaAndExit(containerIdentifier:)` at the start of `init` (one-shot: no store is opened, the app exits after printing the result — tearing down a loaded `NSPersistentCloudKitContainer` crashes its background mirroring) (throwaway `NSPersistentCloudKitContainer` on a temporary empty store built from `NSManagedObjectModel.makeManagedObjectModel(for: WorklogSchema.models)`, then `initializeCloudKitSchema()`); see README checklist.
- **`withAppServices`** adds `.environment(services.profiles)`: main window, MenuBarExtra panel and label, overlay panel; sheets/popovers inherit it. Views that may be hosted elsewhere must get it explicitly (F1's `LiveEnvironmentBridge`).
- **`WindowRouter`:** `@ObservationIgnored weak var profiles: ProfileStore?`; `showSession(_:)` first selects the session's effective, non-archived profile when it isn't current.
- **`WorklogCommands`:** Start/Stop starts in the current profile (`engine.start(label: engine.defaultLabel(for: p), profile: p)`); View menu "Next Profile" (`.nextProfile`) → `profiles.selectNext()`, disabled with fewer than 2 profiles (`NextProfileCommandButton`).
- **`RootView` sidebar inset:** mini status row (while active) → Divider → `ProfileSwitcher()` (always, padding h `spacingS`, v `spacingXS`) → Divider → footer. The mini row shows a `ProfileBadge(.small)` before the label when there are 2+ profiles and the running session's profile isn't current.
- **`PreviewData`:** "Work" (default uuid, default label "Deep work") and "Personal" (`house.fill`, `#27AE60`) with a Personal-local label "Errands" and tag "family"; 9 / 3 sessions.

### 12.8 Pitfalls

- No relationship key paths in `#Predicate`; filter in memory.
- `@Environment(ProfileStore.self)` traps if missing — `withAppServices` injects it; pickers take `profileID` explicitly and never read the store.
- Deleted models: guard with `ModelLiveness`; use UUID tags in pickers and popovers.
- Insert a model before relating it.
- Repair and migration never touch `modifiedAt` (session dedupe and merge import depend on it).
- `lastTakeaway` is computed; observation tracks it through `takeaways`, `activeSession` and the observed `ProfileStore`.
- Old app versions can't see profiles; their new sessions arrive unassigned and are repaired. Upgrade every Mac.
- Deploy the CloudKit schema to Production (new record type + three fields).

---

## 13. Round 4: inline profile list, grid overlay layout

Round 4 replaces the profile switcher's popover with an inline list in the sidebar, shrinks the edit badges and turns the overlay's ordered list into a 6-column grid. The design side is in `docs/DESIGN.md` §17.

### 13.1 Ownership

| Agent | Owns |
|---|---|
| ENG | `Services/OverlayLayout.swift` (grid model), `Services/AppSettings.swift`, `App/RootView.swift`, `WorklogTests/OverlayLayoutTests.swift`, `WorklogTests/OverlayGridLayoutTests.swift`, this document |
| DES | `DesignSystem/**` (`EditModeChrome`: `RemoveBadgeButton`, `editRemoveBadge`, `EditResizeHandle` + `EditResizeHandle.center(in:)` + `View.editResizeHandle(_:gesture:)` — the only way to place the handle, applied before `editRemoveBadge` so their hit areas never overlap —, `AddBadgeButton`), `Shared/**` (`ProfileSwitcher` inline list), `docs/DESIGN.md` |
| F-OVERLAY | `Features/Overlay/**` (`OverlayContent`, `OverlayLayoutEditor`, `OverlayView`, `OverlayGridViews`), `Features/Settings/SettingsOverlayTab.swift` |

New files (`OverlayGridLayoutTests.swift`, `OverlayGridViews.swift`) are added to `Worklog.xcodeproj` by running `python3 scripts/generate_xcodeproj.py`.

### 13.2 Grid model (`Services/OverlayLayout.swift`)

Six columns across the overlay's content width (276 pt regular, 204 pt compact), gutter `spacingXS`; column step = (width + gutter) / 6. Rows have intrinsic height and every element is one row high. **Row 0 is the header row**: it always exists (possibly empty) and renders next to the dot; body rows are 1…n and empty body rows never persist.

```swift
extension OverlayElement {
    var defaultSpan: Int { get }            // label 4, timer 6, segmentFocus 6, controls 2, split 1, todayTotal 2, note 6, takeaway 6
    var minSpan: Int { get }                // label 2, timer 3, segmentFocus 3, controls 2, split 1, todayTotal 2, note 3, takeaway 3
    var prefersTrailing: Bool { get }       // true only for .todayTotal
    var isInlineInLegacyLayout: Bool { get } // label, controls, split, todayTotal (list → grid migration only)
}

struct OverlayPlacement: Codable, Hashable, Identifiable, Sendable {
    var element: OverlayElement; var row: Int; var column: Int; var span: Int
    var id: OverlayElement { element }
    var columnRange: Range<Int> { get }     // column ..< column + span
    var endColumn: Int { get }              // column + span
    init(element: OverlayElement, row: Int, column: Int, span: Int)
    func overlaps(_ other: OverlayPlacement) -> Bool   // same row, intersecting columns
}

enum OverlayGridDirection: CaseIterable, Sendable { case left, right, up, down; var title: String { get } } // "Move Left"…

struct OverlayGridRenderRow: Equatable, Identifiable, Sendable { let row: Int; let placements: [OverlayPlacement]; var id: Int { row } }
struct OverlayGridRenderRows: Equatable, Sendable { let header: OverlayGridRenderRow; let body: [OverlayGridRenderRow] }

struct OverlayGridLayout: Codable, Hashable, Sendable {
    static let columns = 6, headerRow = 0, currentFormatVersion = 1
    private(set) var placements: [OverlayPlacement]          // ALWAYS normalized
    init(placements: [OverlayPlacement])
    static let empty: OverlayGridLayout
    static let defaultLayout: OverlayGridLayout              // = migrated(from: OverlayElement.defaultLayout)
    static func migrated(from list: [OverlayElement]) -> OverlayGridLayout

    var rowCount: Int { get }; var readingOrder: [OverlayElement] { get }
    var elements: Set<OverlayElement> { get }; var hiddenElements: [OverlayElement] { get }
    func contains(_:) -> Bool; func placement(of:) -> OverlayPlacement?; func placements(inRow:) -> [OverlayPlacement]
    func isFree(row: Int, columns: Range<Int>, excluding: OverlayElement? = nil) -> Bool
    func firstFreeCell(span: Int, preferTrailing: Bool = false) -> (row: Int, column: Int)
    func maxSpan(for:) -> Int

    func adding(_:) -> Self; func removing(_:) -> Self
    func moving(_:toRow:column:) -> Self; func displaced(byMoving:toRow:column:) -> Set<OverlayElement>
    func resizing(_:toSpan:) -> Self; func nudged(_:_:) -> Self
    func canNudge(_:_:) -> Bool; func canResize(_:by:) -> Bool
    func renderRows(isVisible: (OverlayElement) -> Bool, headerInline: Bool,
                    widening: Set<OverlayElement> = []) -> OverlayGridRenderRows
}

struct OverlayGridGeometry: Equatable {   // pure drag/snap math; all frames in ONE coordinate space ("overlayGrid")
    var rowFrames: [Int: CGRect]; var gutter: CGFloat
    func columnStep(row:) -> CGFloat                        // (width + gutter) / 6; 0 for an unknown row
    func snappedColumn(leadingX:row:span:) -> Int           // round((x − minX) / step), clamped 0...(6 − span)
    func snappedRow(midY:) -> Int?                          // gap midpoints split rows (a midpoint goes to the lower row)
    func cellFrame(row:column:span:) -> CGRect?             // x = minX + column·step, width = span·step − gutter
    func snappedSpan(trailingX:row:column:) -> Int          // round((x − minX + gutter) / step) − column, clamped 1...6
}
```

**Normalization** (`init(placements:)`, decoding, migration and every "-ing" edit end with it):
1. Drop duplicates (first in input order wins).
2. Clamp `span` to `max(minSpan, min(span, 6))`, `column` to `0...(6 − span)`, `row` to `≥ 0`.
3. Per source row (ascending), sorted by (column, input index), put each placement in the first "line" where it overlaps nothing, else a new line.
4. Row 0's first line is the header; its extra lines become the first body rows; other rows' lines follow in order.
5. Drop empty body lines, renumber (header 0, body 1, 2, …), sort by (row, column).

Equality depends on this: two layouts that look the same are equal. Views never build `[OverlayPlacement]` by hand; they call the model's functions.

**Migration** (`migrated(from:)`, round-3 list → grid): sanitize the list; start in the header row, cursor 0. An inline element wraps to a new row when `cursor + defaultSpan > 6`, then takes `defaultSpan` at the cursor. A full-width element starts a new row when the current row is the header or isn't empty, takes `(row, 0, 6)`, and closes the row. Finally, a row whose last placement is `.todayTotal` moves it to `6 − span`. Postcondition: `readingOrder == sanitized(list)`.

Default grid: `label (0,0,4)`, `timer (1,0,6)`, `segmentFocus (2,0,6)`, `controls (3,0,2)`, `split (3,2,1)`, `note (4,0,6)`, `takeaway (5,0,6)`.

**Edits** (return a new normalized layout, or `self` when the edit doesn't apply):
- `adding`: at `firstFreeCell(defaultSpan, prefersTrailing)` (first body row with room, top to bottom; else a new row; never the header). No-op if present.
- `removing`: the row collapses when it becomes empty (the header stays).
- `moving(e, toRow: r, column: c)`: `r` clamped to `0...rowCount` (`rowCount` = a new trailing row), `c` to `0...(6 − span)`. **Push-down**: the elements of row `r` that overlap the target columns (`displaced(...)`) move together into a new row inserted directly below; later rows shift down. The vacated row collapses.
- `resizing`: clamped to `[minSpan, maxSpan(for:)]` (the next element to the right). Never pushes.
- `nudged`:
  - `.left`/`.right`: one column if that column is free, else swap with the adjacent neighbour (the pair keeps its block; other gaps are kept), else no-op.
  - `.up`: `moving(e, toRow: row − 1, column: column)`; no-op in the header.
  - `.down`: `moving(e, toRow: row + 1, column: column)`, **except** when `e` is alone in a body row. That row collapses once `e` leaves, so a plain push-down would put `e` straight back above the next row (a no-op for stacked full-width rows). Instead the elements of the next row that overlap `e` stay where they are (they move up), and `e` plus the rest of that row go below them: full-width rows swap, mirroring `.up`. Alone in the last row: no-op.
  - `canNudge` / `canResize` = "the edit changes the layout".

**Rendering** (`renderRows`): per row, the visible placements. Each element in `widening` spans from the end of its visible left neighbour (else 0) to the start of its visible right neighbour (else 6); neighbours are processed left to right so two widened elements never overlap. `headerInline` (editing or a session is active) keeps row 0 as `header`; otherwise `header` is empty and row 0's visible items lead `body`. `body` holds only non-empty rows.

**Codable**: `{"columns":6,"formatVersion":1,"placements":[{"column":0,"element":"label","row":0,"span":4},…]}`. Decoding is lenient: unknown elements (and malformed entries) are skipped via a private lossy wrapper, a different `columns` count is rescaled to 6 (`round(value · 6 / stored)`, span ≥ 1), a higher `formatVersion` is accepted, unknown keys are ignored. A missing `placements` key throws. The result is normalized.

### 13.3 `AppSettings`

```swift
var overlayGrid: OverlayGridLayout { didSet { persistOverlayGrid() } }   // source of truth
var overlayLayout: [OverlayElement] { get set }   // COMPATIBILITY: get = readingOrder, set = overlayGrid = .migrated(from:)
func overlayShows(_:) -> Bool                     // overlayGrid.contains
func resetOverlayLayout()                         // overlayGrid = .defaultLayout
func resetOverlayDefaults()                       // overlayGrid = .defaultLayout + the appearance defaults (as round 2)
```

- **Keys:** `settings.overlayGrid` holds the grid as JSON `Data` (`JSONEncoder`, `.sortedKeys`). `settings.overlayLayout` mirrors the reading order as `[String]` raw values, so a round-3 build still shows the same elements in reading order after a downgrade. The legacy `settings.overlayShow…` booleans are never touched.
- **Loading** (`loadOverlayGrid(_:) -> (grid, migrated)` in `init`):
  1. `mirror` = the sanitized `settings.overlayLayout` array, or nil.
  2. The stored grid decodes **and** `mirror` is nil or equals its reading order → use it (`migrated = false`).
  3. Otherwise, with a mirror (no grid yet, corrupt grid data, or a mirror changed by an older build) → `migrated(from: mirror)`. The user's visible elements are never lost.
  4. Otherwise the round-1 booleans (§11.2), migrated.
- **Writing at launch:** a migrated grid is persisted (grid + mirror). A stored grid is **never re-encoded** at launch, so fields added by a newer version survive; only the mirror is refreshed.
- **Every change** to `overlayGrid` (including through `overlayLayout` and the resets) writes both keys.

### 13.4 `RootView`: inline profile list

- State: `@State isProfileListExpanded` (the sidebar owns it so a click elsewhere in the sidebar can collapse it) and `@State sidebarHeight`.
- `ProfileSwitcher(isExpanded: $isProfileListExpanded, maxMenuHeight: ProfileSwitcher.menuHeightLimit(sidebarHeight: sidebarHeight))` sits in the bottom `safeAreaInset`, between the mini status row and the footer. The list expands upward inside the inset, so the footer never moves.
- **Click to collapse:** the `List` carries `.simultaneousGesture(TapGesture().onEnded { collapseProfileList() })`. It never swallows the click (row selection still happens; there is no overlay layer). It is applied **before** `.safeAreaInset`, so clicks in the switcher, the mini status row or the footer don't reach it. Clicks in the detail pane don't collapse the list.
- **Sidebar height:** a `.background { GeometryReader }` (measurement only, never affects layout) feeds `sidebarHeight` through `onAppear`/`onChange(of: proxy.size.height)`. `onGeometryChange` needs macOS 15. The limit `min(360, max(120, h · 0.5))` keeps the inset bounded by the measured sidebar, never by data, so the window's 900×600 minimum can't grow.
- **Collapse** (`collapseProfileList()`: no-op when collapsed; `.easeOut(0.18)`, none under Reduce Motion) on: the mini status row, the account button and the gear (before their action), any `router.selection` change, and any `auth.needsWelcome` change.

### 13.5 Pitfalls

- macOS 14: no `onGeometryChange`/`onScrollGeometryChange`, no `@Entry`.
- Keep the List's collapse gesture before `safeAreaInset` (and simultaneous, never an overlay that eats clicks), and the sidebar `GeometryReader` in a background.
- Never build placements in views; `placements` is `private(set)` and every path normalizes.
- Don't re-encode the stored grid at launch unless it was migrated; always write the mirror; never touch the legacy keys.
- Drag math (`OverlayGridGeometry`), row frames and the drag gesture must share the `"overlayGrid"` coordinate space.
- Run `python3 scripts/generate_xcodeproj.py` after adding files.

### 13.6 Tests

- `OverlayGridLayoutTests` (pure model): default grid, migration (reading order, wrapping, today's total trailing, duplicates), normalization (clamps, overlap push-down, empty-row collapse), move/push-down/new row/vacated row/header, `displaced`, resize clamps, nudges (free move, swap, up/down incl. the alone-in-row case), `firstFreeCell`, add/remove, Codable (round trip, sorted-keys bytes, unknown elements, rescaling, future version, missing placements, overlapping data), `renderRows` (active, idle demotion and widening), geometry at 276 and 204 pt.
- `OverlayLayoutTests` (`AppSettings`): the round-2 tests (via the compatibility accessors and the mirror key) plus fresh install, list-only and boolean migration, stored grid winning, older-build mirror, corrupt data, byte-identical launch, empty grid, `overlayLayout` setter, resets and mirror updates.

---

## 14. Round 4a/4b: release hardening

Round 4a made the app safe to use daily with real data; round 4b fixed functional bugs and split the largest files. The code's doc comments are the detailed reference; this section is the map.

### 14.1 Build and identity

- Release: bundle id `app.dabora.worktracker`, `WorklogRelease.entitlements` (CloudKit **Production**; `aps-environment` `development` in the file, `production` after the Developer ID export), hardened runtime, Developer ID + notarization. Debug: `app.dabora.worktracker.debug`, `Worklog.entitlements` (CloudKit Development), its own sandbox container, store, defaults and keychain items.
- `Entitlements.cloudKitEnvironment` reads the signed `com.apple.developer.icloud-container-environment` (absent → Development); `Entitlements.cloudKitContainerIdentifier` reads the container from the entitlements.

### 14.2 Data safety (round 4a; never weaken these)

- **Opening the store** (`PersistenceController.init`, in order): PreOpen snapshot (APFS copy of the store files into `Recovered/PreOpen-<UTC stamp>/` whenever version, build, configuration, CloudKit environment or model hash changed; the newest two are kept) → a pending "Move to iCloud <env>" / "Use iCloud <env> Data" marker (moves the old store files aside to `Recovered/Env-<env>-<stamp>/` first; skipped while a restore breadcrumb exists) → **environment guard** (`environmentDecision`: CloudKit only when the store's recorded environment matches this build, or the store is new / never synced; otherwise local-only with `environmentMismatch`, never a silent switch) → CloudKit → local-only → in-memory. An incompatible store that looks newer (`storeLooksNewer`) sets `isStoreFromNewerVersion`: Recover is not offered and the store is never moved.
- **Recovery:** the on-disk store is never deleted. Recover… moves it to `Recovered/Store-<stamp>/` (`quarantineStore()`, only in recovery mode; it also clears the recorded CloudKit environment, so the fresh store adopts the build's) and writes `pending-restore.json` (`scheduleRecovery`); the next launch writes `restore-in-progress.json` (`RestoreBreadcrumb`), removes the marker **before** the attempt (one attempt only), then imports the chosen backup (Replace only into an empty store, else Merge after a safety backup) and removes the breadcrumb. A breadcrumb found at launch means that restore was interrupted (`AppServices.launchRestoreStep` → `.reportInterrupted`): "The last restore didn’t finish. Restore “<file>” from Settings ▸ Data." with "Restore…"; nothing is retried. In recovery mode, changed data is written to `Recovered/Unsaved-<stamp>.json` on quit.
- **Environment mismatch** (Settings ▸ Data): **Move to iCloud <env>…** (verified pinned full backup → marker with the backup → relaunch → store moved aside, fresh CloudKit store, backup restored; the notice reports sessions and images not restored and then offers "Restore…"), **Use iCloud <env> Data…** (same verified pinned backup, but the marker has no backup — `PendingRestore.adoptsCloudData` — so the fresh CloudKit store only downloads; `seedDefaults` then waits up to 10 min for the first import; for a second Mac whose data the first Mac already moved), **Keep Local Only**. The verified backup fails only for images the store has bytes for (`BackupService.imagesFailingVerification`); images CloudKit never downloaded to this Mac can't be backed up.
- **Saving:** static edit helpers save through `SafeSave.save(_:source:)` (rollback + `.worklogSaveFailed` → `engine.lastError` alert).
- **Backups:** verified full backups; image files a backup reuses get a fresh modification date when it is captured (`touchImageFiles`), so the image GC's 1 h grace period covers them until the JSON exists; `BackupReason.beforeChange` safety backups before destructive operations; the newest backup with sessions is never pruned; after an iCloud account change the newest backup with sessions is pinned and `AppServices.checkDataShrinkage()` warns (once per count, for 7 days) when the store has under half its sessions. That notice offers "Restore…" (`persistence.launchNoticeOffersRestore`).
- **Dedupe** (`SeedData.deduplicate`): survivors chosen only by synced values (`createdAt`/`modifiedAt` + `instanceID`); an undecidable tie deletes nothing.
- **One instance** (`SingleInstanceGuard`): a second process exits before opening the store; a relaunch waits for the old one to quit.
- Tests: `PersistenceGuardTests`, `DataSafetyTests`, `BackupRetentionTests`, `RecoveryPathTests` (the latter runs against a temporary folder through `AppConstants.rootDirectoryOverride`).

### 14.3 Round 4b APIs

- **`WindowRouter`** (§3.12): `presentedChildSheets` + `childSheetDidAppear()`/`childSheetDidDisappear()` (every sheet in the main window except the review calls them in onAppear/onDisappear); `requestReview()` ("Review…" in the menu bar and overlay); `stopSession(_:)` (the only stop path for commands, menu bar and overlay: shows the main window only when a review is pending); `historyFilterResetRequest` (bumped by `showSession`; History clears filters/search); while Welcome is on screen (`auth.needsWelcome`), `requestNoteFocus/Split/Discard` only bring the window forward — no counter is bumped, so nothing fires after sign-in.
- **`SessionEngine`** (§3.4): start tags on the first segment; persisted pending review; per-session "Keep going" (`isLongSessionWarningDismissed(for:)`, `dismissLongSessionWarning(for:)`); `defaultLabel(for:)` and `totalActiveToday(now:scope:)` delegate to `LiveStartChoice` / `LiveDayMath` in `Services/LiveSessionRules.swift`; file split into extensions.
- **`ExportService`**: split into `ExportService+Import.swift` and `ExportService+Mapping.swift` (pure moves).
- **`WorkSession.pauseIntervals`** decodes through `PauseIntervalsCache` (NSCache keyed by the JSON bytes, so any change — local, import or sync — is a new key).
- **`ProfileStore.showsProfileScope`**: profiles + archived profiles > 1 (badges, scope pickers, per-profile usage).
- **`TaxonomyOps`** (§3.6): creating an archived tag's/label's name unarchives it; `archivedTag(named:profile:in:)`, `archivedLabel(named:profile:in:)`, `unarchive(_:)`, `clearDefaultLabel(_:in:)`.
- **`AttachmentImporter`** (§3.11): `await addFromOpenPanel(to:in:)` downscales off the main thread (`PreparedImage`). Round 4 final: drop/paste use `await addInBackground(_:to:in:)` (`prepareImages` off-main); the synchronous `addFromOpenPanel` is gone.
- **Round 4 final:** `OverlayPanelController.makePanelKey()` / `releaseKeyFocus()` replace `OverlayKeyFocus`; `View.countsAsChildSheet(isPresented:)` replaces `liveChildSheet`; `View.editResizeHandle(_:gesture:)` and `EditResizeHandle.center(in:)` place the overlay editor's resize handle.
- **`LiveTicker`** (`Features/LiveSession/LiveTicker.swift`): the one "tick every second while running" view (`.periodic(from:by: 1)`, stable identity, no updates while paused); RootView's mini timer uses it.
- **`PersistenceController.launchNoticeOffersRestore`**: the launch notice gets "Restore…" (Settings ▸ Data).
- Tests added: `StatsCalculatorTests`, `LiveRulesTests`, `EngineStateTests`, `RecoveryPathTests`.
