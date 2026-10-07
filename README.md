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
- **Themes**: Graphite (the default, a neutral sans-serif look) plus the optional Paper and Meadow themes, light/dark/system appearance and an accent colour.
- **Images**: add them by picking files, pasting or dragging. They are downscaled to 2048 px and compressed, and sync through iCloud.
- **Account**: Sign in with Apple, or continue without signing in.
- **Data**: JSON export and import (merge or replace), CSV export (sessions and segments), rolling local backups with restore, and a recovery flow if the data store can't be opened.
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

- macOS 14 Sonoma or later (deployment target)
- Xcode 16 or later (Swift 5 language mode)

## Setup

### Quick start (no Apple Developer team)

A fresh checkout builds and runs without any signing setup:

Open `Worklog.xcodeproj` in Xcode and press Run (⌘R). There is nothing to install or generate.

`Config/Signing.xcconfig` defaults to ad-hoc signing ("Sign to Run Locally") with the reduced entitlements file
`Worklog/Resources/WorklogLocal.entitlements` (sandbox, user-selected files, network client). In this mode:

- the app detects the missing iCloud entitlement at runtime and uses a local-only store; Settings ▸ Account explains why;
- Sign in with Apple shows a hint to continue without signing in;
- everything else works, including local backups, export and import.

Add and remove files in Xcode as usual. (`scripts/generate_xcodeproj.py` can rebuild the project from the folders on
disk, which is useful only when files were added outside Xcode, e.g. by tooling on a machine without Xcode.)

### With your team (iCloud sync + Sign in with Apple)

1. **Use your own identifiers.** Replace the placeholders (each appears in several files):

   | Placeholder | Where to change it |
   |---|---|
   | Bundle id `com.example.worklog` | Xcode ▸ Worklog target ▸ Signing & Capabilities ▸ Bundle Identifier (and `com.example.worklog.tests` for WorklogTests); also `BUNDLE_ID` in `scripts/generate_xcodeproj.py` |
   | Bundle id `com.example.worklog` | `Worklog/App/AppConstants.swift`: `AppConstants.bundleID` (log subsystem; the Keychain uses the running bundle id) |
   | CloudKit container `iCloud.com.example.worklog` | `Worklog/Resources/Worklog.entitlements`: `com.apple.developer.icloud-container-identifiers` |
   | CloudKit container `iCloud.com.example.worklog` | `Worklog/App/AppConstants.swift`: `AppConstants.cloudKitContainerID` (fallback only — at runtime the id is read from the entitlements) |

2. **Set your team** in a git-ignored local config:

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   # edit WORKLOG_TEAM = <your Team ID>, then reopen the project in Xcode
   ```

   `Local.xcconfig` switches signing to "Apple Development" and the entitlements to `Worklog/Resources/Worklog.entitlements`.

3. **Enable capabilities** for the App ID in the Apple Developer portal (automatic signing usually does this):
   - iCloud, with CloudKit and the container above (create the container if needed)
   - Push Notifications, which CloudKit uses to deliver changes silently
   - Sign in with Apple

4. **Before the first release**, open the CloudKit Console and **deploy the development schema to Production**. Development builds create the schema automatically, production builds can't. Schema changes must be additive only: new properties need defaults, and fields can't be renamed or removed. Free-text fields are marked `allowsCloudEncryption` (see *Privacy*); that choice can't be changed for a field after the schema is deployed to Production. If your development container already has these fields unencrypted from an earlier build, reset the development environment in the CloudKit Console first.

5. **Developer ID distribution** (outside the Mac App Store): Worklog.entitlements uses the development push environment. For a Developer ID build set `com.apple.developer.aps-environment` to `production` and add `com.apple.developer.icloud-container-environment` = `Production`, otherwise the app talks to the development CloudKit database.

### Tests

```sh
xcodebuild test -project Worklog.xcodeproj -scheme Worklog -destination 'platform=macOS'
```

The unit tests run in in-memory SwiftData containers. Under XCTest, `AppServices.shared` is in-memory too, so tests never touch your real data. They cover:
- session math: pauses, midnight crossing, segments
- the session engine state machine (including the two-Mac handoff and deferred discard)
- `SessionEditor` split, merge, delete and move-boundary invariants
- a JSON export → import round trip, merge never overwriting newer data, CSV quoting and the formula-injection guard
- duplicate-row tie-breaking and the backup retention policy

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
                  AttachmentImporter, AppSettings, OverlayPanelController, SyncMonitor (iCloud status)
  Utilities/      Formatting helpers, Log
  DesignSystem/   Theme, ThemeManager, components (designer-owned)
  Shared/         Data-bound pickers shared by features
  Features/       LiveSession, MenuBar, Overlay, History, SessionDetail, Learning, Stats, Settings
WorklogTests/     XCTest
Config/           Signing.xcconfig (defaults) + optional git-ignored Local.xcconfig (your team)
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

**Store.** SwiftData stores everything in a single file (plus `-wal`/`-shm` and a `.Worklog_SUPPORT` folder for images):

```
~/Library/Containers/com.example.worklog/Data/Library/Application Support/Worklog/Worklog.store
```

**Sync.** `PersistenceController` tries these in order:

1. **CloudKit** (private database): used when iCloud sync is on in Settings and the build has the iCloud entitlement. Sync uses the Mac's iCloud account and is independent of Sign in with Apple. If the Mac isn't signed in to iCloud, CloudKit simply waits; Settings ▸ Account shows the account state, the last sync time and any sync error (`SyncMonitor`, from CloudKit's account status and the store's sync events).
2. **Local only**: the same file without CloudKit, used when sync is off, the build has no iCloud entitlement, or CloudKit fails to load. Worklog shows a dismissible banner explaining why (not when you turned sync off yourself).
3. **In memory**: used only if the store file can't be opened at all. Worklog shows a persistent error banner with **Recover…** (see below). Nothing is written to disk in this mode except, on quit, a copy of anything you changed (`Recovered/Unsaved-<date>.json`, importable via Settings ▸ Data ▸ Import).

Changing the iCloud sync toggle takes effect at the next launch.

**CloudKit model rules.** The model follows them throughout:
- every attribute is defaulted or optional
- every relationship is optional with an inverse
- no unique constraints and no ordered relationships
- images use external storage, so they sync as CKAssets

**Two Macs.**
- Default labels and tags are seeded with fixed UUIDs. On a new Mac with sync on, seeding waits for the first iCloud download (up to a minute) and only seeds if no labels arrived, so defaults you deleted elsewhere don't come back.
- Copies of the same label, tag or session (e.g. the same backup restored on two Macs) are merged on launch and activation (`SeedData.deduplicate`). Every row also carries an `instanceID`, so all Macs keep the *same* copy; when two copies can't be told apart, both are kept rather than risking deleting both.
- A session running on one Mac shows as running on the other after sync. Only the Mac that controls it auto-pauses it on sleep or quit. If both Macs had a session running, the older one ends when the newer one started (or at its last activity if that was more than the long-session warning ago), and Worklog says so.

**Backups.** Rolling JSON snapshots are written to:

```
…/Application Support/Worklog/Backups/Worklog-Backup-<UTC date>Z-<reason>-n<sessions>.json
…/Application Support/Worklog/Backups/Attachments/<image id>.jpg|png
```

- Backups are taken on a schedule (default hourly, only when data changed locally or via iCloud), on quit (only when something changed), manually, and automatically before every restore or import (merge or replace).
- Images are stored once in `Backups/Attachments` and referenced from the JSON, so hourly backups stay small and are written off the main thread. Older backups with embedded images still restore. Copy the `Attachments` folder along with a backup file if you move it elsewhere.
- Retention: the newest *N* automatic backups (configurable, default 10), plus the newest per day for 14 days and per week for 8 weeks; the newest 20 manual / before-restore backups; pinned backups are never removed, and neither is the newest backup that contains sessions.
- Shrinkage guard: if a new backup has far fewer sessions than the previous one (under half of more than 10, or none at all), the previous backup is pinned. Automatic backups of an empty store are skipped when the previous backup had sessions.
- Automatic backups are skipped while the app runs on the in-memory fallback, so a bad launch can't rotate good backups out.
- You can restore from Settings ▸ Data:
  - **Merge** adds what's missing and updates a session only when the backup's copy is newer. It never removes local notes, images or learning points, never renames existing labels or tags, and never touches a running session.
  - **Replace** wipes first and is blocked while a session is running.

**Recovery.** If the store can't be opened, **Recover…** moves the damaged store files aside to `Application Support/Worklog/Recovered/Store-<date>/` (nothing is ever deleted), then relaunches Worklog with a fresh store and either restores the backup you chose (replace when local-only, merge when iCloud sync is on) or, with iCloud sync on, downloads your data again. When a new app version first launches, Worklog also copies the store to `Recovered/PreOpen-<date>/` (the last two are kept) before opening it, so a failed upgrade can be undone by hand.

**Export and import.**
- **JSON:** versioned (`formatVersion`), ISO-8601 dates, images optional as base64. Imported images are checked to be JPEG/PNG/HEIC of sane size.
- **CSV:** one file per session or per segment, RFC 4180 quoting. Values starting with `=`, `+`, `-`, `@`, tab or CR get a leading `'` so spreadsheet apps don't run them as formulas.
- **Importing:** importing an archive exported without images keeps the images already in the store, in merge mode.
- **Images you add** are limited to 100 MB files and 150 megapixels, then downscaled to 2048 px.

**Privacy.** Session titles, learnings, takeaways, notes, learning points, segment focus and image captions are stored with CloudKit encryption (`@Attribute(.allowsCloudEncryption)`), so they are encrypted with keys from the user's iCloud Keychain. Sign in with Apple identifiers live in the Keychain (data-protection keychain, this device only, when the app is signed with a team). Logs mark user content as private.

Signing out never deletes data. Neither does revoking Sign in with Apple; it only brings back the welcome screen.

## Known items to verify on a device

These can't be checked in CI and should be tried on real Macs before a release:

- **Toggling iCloud sync** reopens the same store file with and without CloudKit. Core Data may log "Forcing into Read Only mode store" or re-import on the next CloudKit launch; check that data survives switching sync off and on again (make a manual backup first).
- **Two Macs**: start sessions on both, let them sync, and check the handoff end time, the "running on another Mac" hint, and that sleeping the idle Mac doesn't pause the other Mac's session.
- **Duplicate merge**: restore the same backup on two Macs with sync on and check that exactly one copy of each session remains on both.
- **Encrypted fields** appear as encrypted in the CloudKit Console and sync between Macs signed in to the same account.
- **Recovery**: corrupt a copy of the store (e.g. truncate `Worklog.store` while the app is quit) and walk through Recover… with a backup and with a fresh store.
- **Keychain**: with a team-signed build, sign in with Apple, quit, relaunch: the account should persist (items migrate from the legacy keychain on first read).
