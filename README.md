# Worklog

A native macOS 14+ work-session tracker built with SwiftUI, SwiftData and CloudKit.

Start a session with a label, pause and resume it, split it into segments when your focus changes, and jot
timestamped notes. When you stop, give the session a title and write down what you learned. Later you can browse,
search and edit your history, follow how your learnings evolve per tag, and look at stats. A menu bar extra and an
optional floating overlay give quick access while you work.

## Features

- **Live sessions**: start, pause and resume, stop or discard. You can split a session into segments (each with its own label, tags and focus) and add timestamped notes.
- **End-of-session review**: title, label and tags, free-text learnings, a short "takeaway" shown in the next session's overlay, and tagged learning points with a 1–5 mastery rating.
- **History**: grouped by day and sortable by date, length or label. Full-text search covers titles, labels, tags, segment focus, notes, learnings and image captions. Every session can be edited after the fact: times, labels, segments (split, merge, delete, move a boundary), notes and images.
- **Learning page**: learning points per tag over time.
- **Stats**: Swift Charts views by label and tag, daily goal and streaks.
- **Menu bar extra**: shows the live timer and gives you controls, a quick note field and the last takeaway.
- **Floating overlay**: a non-activating `NSPanel` that stays above other apps. Each section, the opacity, the level and the Spaces behaviour can be configured.
- **Themes**: three themes (Paper, Graphite, Meadow), light/dark/system appearance and an accent colour.
- **Images**: add them by picking files, pasting or dragging. They are downscaled to 2048 px and compressed, and sync through iCloud.
- **Account**: Sign in with Apple, or continue without signing in.
- **Data**: JSON export and import (merge or replace), CSV export (sessions and segments), and rolling local backups with restore.
- **Keyboard**:

  | Action | Shortcut |
  |---|---|
  | Start/stop | ⌘⇧S |
  | Pause/resume | ⌘⇧P |
  | Add note | ⌘⇧N |
  | Split | ⌘⇧D |
  | Toggle overlay | ⌘⇧O |
  | Today, History, Learning, Stats | ⌘1–⌘4 |

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup

1. **Generate the project.** The `.xcodeproj` is generated, not committed:

   ```sh
   brew install xcodegen
   xcodegen generate
   open Worklog.xcodeproj
   ```

   Run `xcodegen generate` again whenever files are added or removed, or `project.yml` changes.

2. **Use your own identifiers.** Search for and replace the placeholders. The default bundle id is `com.example.worklog` and the default CloudKit container is `iCloud.com.example.worklog`. Each placeholder appears in several files:

   | Placeholder | Where to change it |
   |---|---|
   | Bundle id `com.example.worklog` | `project.yml`: `bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER` for the app and the tests |
   | Bundle id `com.example.worklog` | `Worklog/App/AppConstants.swift`: `AppConstants.bundleID`, also used for the Keychain service and log subsystem |
   | CloudKit container `iCloud.com.example.worklog` | `Worklog/Resources/Worklog.entitlements`: `com.apple.developer.icloud-container-identifiers` |
   | CloudKit container `iCloud.com.example.worklog` | `Worklog/App/AppConstants.swift`: `AppConstants.cloudKitContainerID` |
   | Team | `project.yml`: set `DEVELOPMENT_TEAM` to your Team ID |

   Then run `xcodegen generate` again.

3. **Enable capabilities** for the App ID in the Apple Developer portal. Xcode's automatic signing usually does this when you build with your team selected.
   - iCloud, with CloudKit and the container above (create the container if needed)
   - Push Notifications, which CloudKit uses to deliver changes silently
   - Sign in with Apple

4. **Before the first release**, open the CloudKit Console and **deploy the development schema to Production**. Development builds create the schema automatically, but production builds can't. Schema changes must be additive only: new properties need defaults, and fields can't be renamed or removed.

### Running without a paid team ("Sign to Run Locally")

iCloud and Sign in with Apple require a team. You can still run everything else locally with the reduced entitlements file `Worklog/Resources/WorklogLocal.entitlements`, which only contains sandbox, user-selected files and network client.

Either edit `project.yml`:

```yaml
CODE_SIGN_ENTITLEMENTS: Worklog/Resources/WorklogLocal.entitlements
```

and set **Signing → Sign to Run Locally** in Xcode, or build from the command line:

```sh
xcodebuild -project Worklog.xcodeproj -scheme Worklog \
  CODE_SIGN_ENTITLEMENTS=Worklog/Resources/WorklogLocal.entitlements \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

In this mode:
- The app detects the missing entitlements at runtime and uses a local-only store. An info banner and the Account settings tab explain this.
- Sign in with Apple shows a hint to continue without signing in.
- Everything else works.

### Tests

```sh
xcodebuild test -project Worklog.xcodeproj -scheme Worklog -destination 'platform=macOS'
```

The unit tests run in in-memory SwiftData containers. Under XCTest, `AppServices.shared` is in-memory too, so tests never touch your real data. They cover:
- session math: pauses, midnight crossing, segments
- the session engine state machine
- `SessionEditor` split, merge, delete and move-boundary invariants
- a JSON export → import round trip and CSV quoting

## Architecture

The full contract (names, signatures, ownership) is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Design tokens are in `docs/DESIGN.md`.

```
Worklog/
  App/            @main WorklogApp (Window + Settings + MenuBarExtra scenes), AppDelegate, AppServices
                  (service container + View.withAppServices), RootView, WindowRouter, commands
  Models/         SwiftData @Model types: WorkSession, Segment, Note, Attachment, WorkLabel, WorkTag, LearningPoint
  Persistence/    PersistenceController (CloudKit → local → in-memory fallback), SeedData, PreviewData
  Services/       SessionEngine (live state machine), SessionEditor (after-the-fact edits), TaxonomyOps,
                  AuthService + KeychainStore, ExportService + DTOs, BackupService, SearchService,
                  AttachmentImporter, AppSettings, OverlayPanelController
  Utilities/      Formatting helpers, Log
  DesignSystem/   Theme, ThemeManager, components (designer-owned)
  Shared/         Data-bound pickers shared by features
  Features/       LiveSession, MenuBar, Overlay, History, SessionDetail, Learning, Stats, Settings
WorklogTests/     XCTest
```

**Services.** All services are `@MainActor @Observable` and are created once in `AppServices`. Every scene root gets them through `.withAppServices(services)`, which injects each service, the `ModelContainer` and the theme. Views read them with `@Environment(Type.self)`. All SwiftData work goes through `container.mainContext`.

**Time math.** Elapsed time is always computed from wall-clock timestamps and never accumulated:
- A session stores `startedAt`, `endedAt` and a list of pause intervals (JSON in `pauseIntervalsData`).
- Active time = wall time − overlap with pauses.
- Segments are contiguous slices of the session.

This makes several things straightforward:
- **Sleep:** the session auto-pauses.
- **Quit and relaunch:** a running session simply keeps counting. `SessionEngine.restoreActiveSession()` adopts it, optionally paused on quit.
- **Per-day stats:** time is clipped to day intervals, so sessions crossing midnight are split correctly.

**Live session flow.**
- `SessionEngine` owns the active session: `start`, `pause`/`resume`, `split`, `addNote`, `stop` and `discard`.
- After `stop`, the session becomes `pendingEndSession`, and `RootView` presents the end-of-session sheet.
- `SessionEditor` performs every after-the-fact edit and re-normalizes segment contiguity each time.

## Data, sync and backups

**Store.** SwiftData stores everything in a single file:

```
~/Library/Containers/com.example.worklog/Data/Library/Application Support/Worklog/Worklog.store
```

**Sync.** `PersistenceController` tries these in order:

1. **CloudKit** (private database): used when iCloud sync is enabled in Settings, the build has the iCloud entitlement, and the Mac is signed in to iCloud. Sync uses the Mac's iCloud account and is independent of Sign in with Apple.
2. **Local only**: the same file without CloudKit, used if any condition above fails or CloudKit fails to load. Worklog shows a dismissible banner explaining why.
3. **In memory**: used only if the store file can't be opened at all. Worklog shows a persistent error banner offering restore from a backup. **The store file is never deleted or moved automatically.**

Changing the iCloud sync toggle takes effect at the next launch.

**CloudKit model rules.** The model follows them throughout:
- every attribute is defaulted or optional
- every relationship is optional with an inverse
- no unique constraints and no ordered relationships
- images use external storage, so they sync as CKAssets

**Two Macs.** Default labels and tags are seeded with fixed UUIDs, so copies created on two Macs are merged on launch or activation (`SeedData.deduplicate`). Merging also ends any extra "running" sessions. A session started on one Mac shows as running on the other after sync.

**Backups.** Rolling JSON snapshots are written to:

```
…/Application Support/Worklog/Backups/Worklog-Backup-<date>-<reason>.json
```

- Backups are taken on a schedule (default hourly, and only when data changed), on quit, manually, and automatically before every restore.
- The number kept is configurable (default 10).
- Automatic backups are skipped while the app runs on the in-memory fallback, so a bad launch can't rotate good backups out.
- You can restore from Settings ▸ Data:
  - **Merge** upserts by UUID and never touches a running session.
  - **Replace** wipes first and is blocked while a session is running.

**Export and import.**
- **JSON:** versioned (`formatVersion`), ISO-8601 dates, images optional as base64.
- **CSV:** one file per session or per segment, RFC 4180 quoting.
- **Importing:** importing an archive exported without images keeps the images already in the store, in merge mode.

Signing out never deletes data. Neither does revoking Sign in with Apple; it only brings back the welcome screen.
