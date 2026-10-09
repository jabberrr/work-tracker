# Worklog

A native macOS 14+ work-session tracker built with SwiftUI, SwiftData and CloudKit.

Start a session with a label, pause and resume it, split it into segments when your focus changes, and jot
timestamped notes. When you stop, give the session a title and write down what you learned. Later you can browse,
search and edit your history, follow how your learnings evolve per tag, and look at stats. A menu bar extra and an
optional floating overlay give quick access while you work.

## Features

- **Profiles**: keep separate sets of sessions ("Work", "Personal", …), each with its own labels and tags, stats, takeaway and default label. Switch with the profile switcher above the sidebar footer (or View ▸ Next Profile); the selection is remembered per Mac. Labels and tags can be available in all profiles or only in one. Stats can show the current profile or all profiles. The menu bar and the overlay start sessions in the *quick start* profile (Settings ▸ Profiles; "Current profile" by default), while ⇧⌘S and Today always use the current profile.
- **Live sessions**: start, pause and resume, stop or discard. You can split a session into segments (each with its own label, tags and focus) and add timestamped notes.
- **End-of-session review**: title, label and tags, free-text learnings, a short "takeaway" shown in the next session's overlay, and tagged learning points with a 1–5 mastery rating.
- **History**: grouped by day and sortable by date, length or label. Full-text search covers titles, labels, tags, segment focus, notes, learnings and image captions. Every session can be edited after the fact: times, labels, segments (split, merge, delete, move a boundary), notes and images.
- **Learning page**: learning points per tag over time.
- **Stats**: Swift Charts views by label and tag, daily goal and streaks.
- **Menu bar extra**: shows the live timer and gives you controls, a quick note field and the last takeaway.
- **Floating overlay**: a non-activating `NSPanel` that stays above other apps. Its layout is editable: in Settings ▸ Overlay you choose which elements it shows (label, timer, segment focus, controls, split, today's total, quick note, takeaway) and drag them into order on a live, real-size preview. Opacity, compact mode, the window level and the Spaces behaviour are configurable too.
- **Themes**: Graphite (the default, a neutral sans-serif look) plus the optional Paper and Meadow themes, light/dark/system appearance and an accent colour.
- **Images**: add them by picking files, pasting or dragging. They are downscaled to 2048 px and compressed, and sync through iCloud.
- **Account**: Sign in with Apple, or continue without signing in. iCloud sync uses the Mac's Apple Account either way.
- **Data**: JSON export and import (merge or replace), CSV export (sessions and segments), rolling local backups with restore, and a recovery flow if the data store can't be opened.
- **Settings in the main window**: Settings is a page of the main window (the gear in the sidebar footer, ⌘, or the app menu's "Settings…"), not a separate window. Sections: General, Appearance, Overlay, Shortcuts, Profiles, Labels & Tags, Account, Data.
- **Customizable keyboard shortcuts**: every app shortcut can be re-recorded, cleared or reset in Settings ▸ Shortcuts. Conflicts, combos reserved by macOS, shortcuts without ⌘ or ⌃ and ⇧ with a digit or symbol are rejected; changes apply immediately and survive relaunch. Defaults:

  | Action | Default |
  |---|---|
  | Start / stop session | ⇧⌘S |
  | Pause / resume | ⇧⌘P |
  | Add note | ⇧⌘N |
  | Split segment | ⇧⌘D |
  | Discard session | – |
  | Toggle overlay | ⇧⌘O |
  | Today, History, Learning, Stats | ⌘1–⌘4 |
  | Switch to next profile | – |
  | Find in History | ⌘F |
  | Save session review | ⌘↩ |

  Fixed (system conventions): ⌘, Settings, ⌘Q, ⌘W, ⌥⌘W, ⌘H, ⌘M, ⌥⌘M, ⌃⌘S Toggle Sidebar, ⌃⌘Space Emoji & Symbols, the Edit menu, Return/Esc in sheets, ⌫ in the History list.

## Requirements

- macOS 14 Sonoma or later (deployment target)
- Xcode 16 or later (Swift 5 language mode)

## Setup

### Quick start

Open `Worklog.xcodeproj` in Xcode and press Run (⌘R). There is nothing to install or generate.

The project is signed with team `6W4ZKDHBVD` (a paid Apple Developer Program membership is needed for iCloud and
Sign in with Apple). The two build configurations are deliberately different apps:

| Configuration | Bundle id | Entitlements | CloudKit environment | Used by |
|---|---|---|---|---|
| Debug | `app.dabora.worktracker.debug` | `Worklog/Resources/Worklog.entitlements` | Development | Run (⌘R), tests |
| Release | `app.dabora.worktracker` | `Worklog/Resources/WorklogRelease.entitlements` | Production (`com.apple.developer.icloud-container-environment`); production push is set by the App Store export | Archive → App Store Connect / TestFlight |

Both use the iCloud container `iCloud.app.dabora.worktracker`. Because the bundle ids differ, a Debug run never opens
the store, backups, settings or keychain items of the app you use every day; it starts with its own empty store
(and downloads whatever the Development environment holds).

Only one copy of each app runs at a time: launching a second instance with the same bundle id brings the running one
to the front and quits, so two processes never open the same store.

To build **without** a paid team: in Xcode ▸ Worklog target ▸ Build Settings set *Code Signing Entitlements* to
`Worklog/Resources/WorklogLocal.entitlements` and pick your Personal Team (or "Sign to Run Locally") under Signing &
Capabilities. The app then uses a local-only store, Sign in with Apple shows a hint to continue without signing in, and
everything else (backups, export, import) still works.

**Project file.** The committed `Worklog.xcodeproj` is generated by `scripts/generate_xcodeproj.py` (run
`python3 scripts/generate_xcodeproj.py` after adding or removing files outside Xcode; the output is deterministic).
Build settings — versions (`MARKETING_VERSION` 1.0.1, `CURRENT_PROJECT_VERSION`), bundle ids, entitlements, signing —
live in that script. Adding files in Xcode is fine, but any build setting you change in Xcode's editor must also be
changed in the script, or the next regeneration silently undoes it. `Info.plist` takes its version, build and minimum
macOS from the build settings (`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`, `$(MACOSX_DEPLOYMENT_TARGET)`).

### Signing, iCloud and Sign in with Apple

1. **Identifiers** (change all of them together if you change one):

   | Identifier | Where |
   |---|---|
   | Bundle id `app.dabora.worktracker` (Debug: `app.dabora.worktracker.debug`, tests: `app.dabora.worktracker.tests`) | `BUNDLE_ID` in `scripts/generate_xcodeproj.py`; `AppConstants.bundleID` (log subsystem and fallback only) |
   | CloudKit container `iCloud.app.dabora.worktracker` | `Worklog.entitlements` and `WorklogRelease.entitlements`; `AppConstants.cloudKitContainerID` (fallback only — at runtime the id is read from the entitlements) |
   | Team `6W4ZKDHBVD` | Xcode ▸ target ▸ Signing & Capabilities (both targets); `DEVELOPMENT_TEAM` in `scripts/generate_xcodeproj.py` |

2. **First signed build.** In Xcode ▸ Worklog target ▸ Signing & Capabilities, check that *Sign in with Apple*, *iCloud*
   (CloudKit, container `iCloud.app.dabora.worktracker` ticked) and *Push Notifications* are listed. If the container is red,
   click the refresh button under Containers (or "+" and enter the id) so Xcode creates it. The Debug bundle id
   `app.dabora.worktracker.debug` is a separate App ID: automatic signing registers it on the first Debug build; make
   sure the iCloud container is ticked for it too.

3. **Enable capabilities** for the App ID in the Apple Developer portal (automatic signing usually does this):
   - iCloud, with CloudKit and the container above (create the container if needed)
   - Push Notifications, which CloudKit uses to deliver changes silently
   - Sign in with Apple

4. **Before the first release**, open the CloudKit Console and **deploy the development schema to Production**. Development builds create the schema automatically, production builds can't. Schema changes must be additive only: new properties need defaults, and fields can't be renamed or removed. **Profiles (round 3)** added the `CD_WorkProfile` record type and a `CD_profile` field on `CD_WorkSession`, `CD_WorkLabel` and `CD_WorkTag`: run a development build against the development container once, then deploy the schema to Production *before* shipping the release, or production builds can't sync profiles. Free-text fields are marked `allowsCloudEncryption` (see *Privacy*); that choice can't be changed for a field after the schema is deployed to Production.

   **Never reset the Development environment** while any build could still open a store that synced with it (every
   store made before this release did): resetting deletes the server copy, and CloudKit can then empty the local
   stores that mirror it. Your data leaves Development only through *Move to iCloud Production* (below).

   **Before shipping a model change (checklist).** A development build only creates the record types and fields for values it actually saved, so a field nobody has used yet (an optional relationship, an archived flag) can be missing from the schema you deploy.
   1. Build the Debug configuration and run it once with the launch argument `-initializeCloudKitSchema` (Xcode ▸ Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments). Before opening its store, Worklog loads the model into a throwaway, empty store and calls `initializeCloudKitSchema()`, which creates every record type and field in the **Development** environment. The console says "CloudKit schema initialized…" (or prints the full error) and **the app then quits by itself** — that's expected; it never opens a store in this mode. Remove the argument afterwards. Your data isn't touched.
   2. In the CloudKit Console, check that `CD_WorkProfile` exists and that `CD_WorkSession`, `CD_WorkLabel` and `CD_WorkTag` have a `CD_profile` field.
   3. Deploy the schema to **Production**, then ship the release.

5. **App Store / TestFlight distribution.** Release signs with `WorklogRelease.entitlements`
   (`com.apple.developer.icloud-container-environment` = `Production`, Sign in with Apple, iCloud, push). Signing is
   automatic. The file's `aps-environment` is `development` on purpose: the Archive is signed with Xcode's development
   profile, which only allows that value; Organizer ▸ **Distribute App** ▸ **App Store Connect** re-signs with the
   Apple Distribution certificate and profile, which set it to `production`. (Developer ID / Direct Distribution
   isn't possible: Apple doesn't offer Sign in with Apple to Developer ID apps.)
   - **App record (once):** App Store Connect ▸ Apps ▸ **+ ▸ New App** ▸ platform *macOS*, bundle ID
     `app.dabora.worktracker`, any SKU. The store name must be unique across the App Store (e.g. "Worklog – Work
     Tracker" if "Worklog" is taken); the installed app is still called Worklog.
   - **Build numbers:** every upload needs a higher build number. Raise `CURRENT_PROJECT_VERSION` in
     `scripts/generate_xcodeproj.py` and re-run it (or change *Build* in Xcode ▸ target ▸ General, and mirror it in
     the script before you next regenerate). Raise `MARKETING_VERSION` for user-visible releases.
   - **Privacy manifest:** `Worklog/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the
     two required-reason APIs the app uses (its own UserDefaults; modification dates of its own backup files).
   - **TestFlight** builds expire after 90 days; upload a new build (or publish on the Mac App Store) before then.
   - **Public App Store release** additionally needs a privacy policy URL, screenshots, and App Review. Review may
     ask about account deletion (guideline 5.1.1(v)): Worklog creates no server account — Sign Out plus
     Settings ▸ Data ▸ *Delete All Data* cover it; mention that in the review notes.

   **Environment guard.** Worklog records which CloudKit environment its store syncs with
   (`persistence.cloudKitEnvironment` in the app's defaults; a store from before this release counts as Development).
   A build whose environment differs never switches silently: it opens the store *local-only*, shows "Saving to this
   Mac only — this data belongs to iCloud Development, not Production", and Settings ▸ Data offers:
   - **Move to iCloud Production…** — for the **first** Mac: makes a pinned backup with every image (read back and
     checked), writes a marker and relaunches. Before opening anything, the next launch moves the old store files to
     `Recovered/Env-Development-<UTC date>/` (never deleted), opens a fresh CloudKit store in Production, restores the
     backup (Replace into the empty store, before any default labels or profiles are created) and shows how many
     sessions came back (and offers **Restore…** if sessions or images are missing). Blocked while a session is running.
   - **Use iCloud Production Data…** — for **every other** Mac, once the first Mac has moved: the same pinned backup,
     then the store is moved to `Recovered/Env-Development-…` and a fresh CloudKit store downloads what Production
     already holds. Nothing from this Mac is uploaded or restored; default labels wait for the download. If this Mac
     holds sessions the first Mac doesn't have, use **Move to iCloud Production…** here too: sessions both Macs have
     are merged automatically (same IDs).
   - **Keep Local Only** — turns iCloud sync off; the data stays on this Mac. Turning sync on later offers the options again.

### Safe first archive (checklist)

Your real data lives in the store of bundle id `app.dabora.worktracker` (the Release app), which so far synced with
CloudKit **Development**. Do these in order, on the Mac with your most complete data first. Steps 1–3 use the
Worklog you use today, *before* any build of this version runs (a Debug build is now a different app, `….debug`, and
doesn't see that data).

1. **Export a copy you control.** Settings ▸ Data ▸ turn on *Include images in JSON* ▸ **Export JSON…** ▸ save to
   `~/Documents`.
2. **Back up and pin.** Settings ▸ Data ▸ **Back Up Now**, then the backup's ••• menu ▸ **Pin**. Note the session count.
   If the old build can't run any more, do steps 1–2 in the new build right after its first launch (step 8, before
   choosing anything): it opens your store local-only and changes nothing.
3. **Quit the old Worklog completely**: Worklog ▸ Quit Worklog (⌘Q). Its menu bar icon must be gone too.
4. **Initialize the schema.** Run the **Debug** configuration once with the launch argument `-initializeCloudKitSchema`
   (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments). The console prints "✅ CloudKit schema initialized…" and the
   app **quits by itself** (expected — it opens no store in this mode; your data isn't touched). Then untick the
   argument. If it prints a failure instead, run it once more (a brand-new Debug App ID can need a minute for iCloud).
5. **Deploy the schema.** CloudKit Console ▸ `iCloud.app.dabora.worktracker` ▸ check `CD_WorkProfile` and the
   `CD_profile` fields exist ▸ **Deploy Schema Changes…** to Production. (Never reset Development.)
6. **Archive and upload.** Create the App Store Connect app record if you haven't (step 5 of *Signing* above).
   Select *Any Mac*, Product ▸ **Archive** (Release, automatic signing), then Organizer ▸ **Distribute App** ▸
   **App Store Connect** ▸ **Distribute** (upload). Wait for the "processing complete" email.
7. **Install through TestFlight.** App Store Connect ▸ your app ▸ **TestFlight** ▸ add yourself to an *Internal
   Testing* group (no review needed) and answer the export-compliance question if asked (the app declares no
   non-exempt encryption). Install the **TestFlight** app from the Mac App Store, accept the invite, and click
   **Install**. Remove or rename any other `Worklog.app` in `/Applications` first if TestFlight asks. Then check:
   ```sh
   codesign -d --entitlements - /Applications/Worklog.app   # icloud-container-environment Production, aps-environment production, applesignin
   ```
8. **First launch.** Open it from TestFlight or /Applications. (macOS may ask once whether Worklog may access its
   own data from the earlier build — allow it.) The banner says "Saving to this Mac only — this data belongs to iCloud Development, not Production."
   Settings ▸ Data ▸ **Move to iCloud Production…** ▸ **Back Up and Relaunch**. After the relaunch the banner says
   "Moved to iCloud Production: N sessions restored. Your previous copy is in the Recovered folder."
9. **Verify.** Compare N with step 2, open a few sessions with images, and check Settings ▸ Account says
   "Syncing with iCloud" (Production). Keep `Recovered/Env-Development-…` and the pinned backup for a while.
10. **Remove old copies.** List every copy of the app and delete all but the TestFlight-installed
    `/Applications/Worklog.app` (archives in Xcode's Organizer may stay). Never run a build from before this version
    again.
    ```sh
    mdfind "kMDItemCFBundleIdentifier == 'app.dabora.worktracker'"
    ```

**Every other Mac** (after step 9 on the first one): back up (steps 1–2), quit the old Worklog (step 3), install
the same build through TestFlight (same Apple Account), then Settings ▸ Data ▸ **Use iCloud Production Data…** ▸ **Back Up and Relaunch**. The banner
says "Now using iCloud Production; downloading your data. Your previous copy is in the Recovered folder." Then do
step 10. Only if that Mac has sessions the first Mac lacks, choose **Move to iCloud Production…** instead (step 8).

### Tests

```sh
xcodebuild test -project Worklog.xcodeproj -scheme Worklog -destination 'platform=macOS'
```

The unit tests run in in-memory SwiftData containers. Under XCTest, `AppServices.shared` is in-memory too, so tests never touch your real data. They cover:
- session math: pauses, midnight crossing, segments, and the pause-interval decode cache
- stats: streaks (including "nothing today yet"), the 60-second active-day minimum, sessions crossing midnight, bucket thresholds, and tag time for segment vs. session tags
- the rules behind Today, the menu bar and the overlay: today's total, the default label, resolving picked labels/tags, the long-session warning and "Keep going"
- the session engine state machine (including the two-Mac handoff and deferred discard, start tags on the first segment, and the review surviving a relaunch)
- creating a tag or label with an archived one's name (it is unarchived instead of duplicated)
- `SessionEditor` split, merge, delete and move-boundary invariants
- a JSON export → import round trip, merge never overwriting newer data, CSV quoting and the formula-injection guard
- duplicate-row tie-breaking and the backup retention policy
- the overlay layout migration from the old per-element toggles, and resetting it
- profiles: the migration of existing data, profile dedupe and repair, `ProfileScope`, scoped tag creation, making labels/tags local (copies for other profiles), moving sessions between profiles, deleting/archiving profiles, the persisted selection, the profile-aware engine (start, default label, today total, per-profile takeaways), scoped search and export format 2 (including importing format-1 files)
- shortcut defaults, display strings, validation (conflicts, reserved combos, missing ⌘/⌃, ⇧ without a letter), clearing, reset (and the action it clears) and persistence (including de-duplicating stored overrides)
- data safety: the CloudKit environment guard's decision table, the interrupted-restore breadcrumb decision and notice, "Use iCloud Production Data" (a move without a restore), the verified backup only failing for images the store has bytes for, the PreOpen snapshot key and model hash, newer-store detection, the restore marker format and restore mode, session dedupe keeping notes/images/learning points, imported running sessions (ended unless this Mac owned them), Replace keeping the store's own images, merge updating re-seeded defaults and newer profiles, reconcile leaving another Mac's just-started session alone, the engine forgetting a deleted active session, and per-kind backup retention
- recovery paths on disk, run in a temporary folder: the restore marker and the restore breadcrumb, PreOpen snapshot pruning, moving a damaged store aside (which clears the recorded CloudKit environment), and a skipped environment move

## Architecture

Files, models, services and their rules are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (§14 covers the release hardening). Design tokens are in `docs/DESIGN.md`.

```
Worklog/
  App/            @main WorklogApp (Window + MenuBarExtra scenes; Settings is a page of the window), AppDelegate,
                  AppServices (service container + View.withAppServices), RootView, WindowRouter, commands
  Models/         SwiftData @Model types: WorkSession, Segment, Note, Attachment, WorkLabel, WorkTag, LearningPoint,
                  WorkProfile
  Persistence/    PersistenceController (CloudKit → local → in-memory fallback), SeedData, PreviewData
  Services/       SessionEngine (live state machine; +Review/+Takeaway/+Ownership/+SystemEvents extensions),
                  LiveSessionRules (today total, default label, long-session warning), SessionEditor (after-the-fact
                  edits), TaxonomyOps, SafeSave, SingleInstanceGuard,
                  AuthService + KeychainStore, ExportService (+Import/+Mapping) + DTOs, BackupService, SearchService,
                  AttachmentImporter, AppSettings, OverlayLayout (overlay elements), ShortcutStore (customizable
                  shortcuts), ProfileStore + ProfileScope (current profile, in-memory scoping), ProfileOps,
                  OverlayPanelController, SyncMonitor (iCloud status)
  Utilities/      Formatting helpers, Log, ModelLiveness
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

**Store.** SwiftData stores everything in a single file (plus `-wal`/`-shm` and a `.Worklog_SUPPORT` folder for images):

```
Release: ~/Library/Containers/app.dabora.worktracker/Data/Library/Application Support/Worklog/Worklog.store
Debug:   ~/Library/Containers/app.dabora.worktracker.debug/Data/Library/Application Support/Worklog/Worklog.store
```

Backups (`Backups/`), recovered and moved-aside stores (`Recovered/`) and the restore marker (`pending-restore.json`)
sit next to it.

**Sync.** `PersistenceController` tries these in order:

1. **CloudKit** (private database): used when iCloud sync is on in Settings, the build has the iCloud entitlement, and the store's recorded CloudKit environment matches the build's (see *Environment guard* above; otherwise the store opens local-only and Settings ▸ Data offers the move). Sync uses the Mac's iCloud account and is independent of Sign in with Apple. If the Mac isn't signed in to iCloud, CloudKit simply waits; Settings ▸ Account shows the account state, the last sync time and any sync error (`SyncMonitor`, from CloudKit's account status and the store's sync events).
2. **Local only**: the same file without CloudKit, used when sync is off, the build has no iCloud entitlement, or CloudKit fails to load. Worklog shows a dismissible banner explaining why (not when you turned sync off yourself).
3. **In memory**: used only if the store file can't be opened at all. Worklog shows a persistent error banner whose **Restore…** button opens Settings ▸ Data, where **Recover…** starts the recovery (see below). Nothing is written to disk in this mode except, on quit, a copy of anything you changed (`Recovered/Unsaved-<date>.json`, importable via Settings ▸ Data ▸ Import). If the store was made by a *newer* Worklog (its model has entities this build doesn't know, or a newer version opened it before), Settings ▸ Data says so and offers no Recover: install the newer version; the store is left untouched.

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

**Profiles.**
- On the first launch of this version, a "Work" profile is created with a fixed UUID and every existing session is put in it. Existing labels and tags become available in all profiles; nothing else is rewritten. When two Macs upgrade, both create the same "Work" profile and the copies are merged after sync (the older one wins).
- A new Mac with iCloud sync creates a provisional "Work" profile at launch so the app always has a profile. After the first iCloud download it is merged into the synced "Work", or removed if it is still empty and you had deleted "Work" on another Mac.
- A session without a profile (created by an older app version on another Mac, or whose profile was deleted on another Mac) is shown in the profile that owns its labels/tags, else in the home profile ("Work" if it exists). With iCloud sync this is display-only: the session gets that profile when you edit it, never in the background, so a Mac that is still downloading a session's profile can't overwrite it. Without iCloud sync it is assigned at launch and activation. Labels and tags whose profile was deleted become available everywhere. Nothing is lost.
- **Upgrade every Mac before creating or using profiles.** Older app versions don't know profiles: their new sessions arrive without a profile (and are shown in the home profile), and they show every profile's sessions and labels together.
- **The upgrade is one-way.** Once this version opens the store, an older build can't read exported files of format 2 and shouldn't be used on the migrated store any more. To go back, use the copy taken before the upgrade (`Recovered/PreOpen-<date>/`, see *Recovery*) or a backup made by the older version.
- Making a label or tag local to one profile while other profiles use it gives each of those profiles its own copy; moving a session to another profile copies the labels and tags that profile doesn't have. A session never ends up with a label or tag its profile doesn't offer.
- The current profile is stored per Mac (`profiles.activeProfileID`); the quick start profile is a setting.

**Backups.** Rolling JSON snapshots are written to:

```
…/Application Support/Worklog/Backups/Worklog-Backup-<UTC date>Z-<reason>-n<sessions>.json
…/Application Support/Worklog/Backups/Attachments/<image id>.jpg|png
```

- Backups are taken on a schedule (default hourly, only when data changed locally or via iCloud), on quit (only when something changed), manually, and automatically before every restore or import (merge or replace).
- Images are stored once in `Backups/Attachments` and referenced from the JSON, so hourly backups stay small and are written off the main thread. Older backups with embedded images still restore. Copy the `Attachments` folder along with a backup file if you move it elsewhere.
- Before deleting, merging or re-scoping a label or tag (Settings ▸ Labels & Tags), and before deleting a profile's sessions, a safety backup is written first; if it fails, nothing changes.
- Retention: the newest *N* automatic backups (configurable, default 10), plus the newest per day for 14 days and per week for 8 weeks; the newest 20 of *each* kept kind (manual, before restore, before change); pinned backups are never removed, and neither is the newest backup that contains sessions. The backups made by *Move to iCloud Production* and *Use iCloud Production Data* are pinned.
- Shrinkage guard: if a new backup has under half the sessions of the previous one (or none at all), the previous backup is pinned. Automatic backups of an empty store are skipped when the previous backup had sessions. When the Mac's iCloud account changes, the newest backup with sessions is pinned, and if the store then holds under half of its sessions, a banner says so and points to it.
- Automatic backups are skipped while the app runs on the in-memory fallback, so a bad launch can't rotate good backups out.
- You can restore from Settings ▸ Data:
  - **Merge** adds what's missing and updates a session only when the backup's copy is newer. It never removes local notes, images or learning points and never touches a running session. Existing labels and tags keep their local name — unless they were created after the backup was made (a re-seeded default), then the backup's values win; a profile is updated when the backup's copy is newer.
  - **Replace** wipes first and is blocked while a session is running. Images the file lacks (exported without images, or missing backup image files — the sheet shows how many) are kept from the store when it still has them.
  - A session that was running in the file is ended at the export time (never adopted as running), unless this Mac was running it.

**Recovery.** If the store can't be opened, **Recover…** moves the damaged store files aside to `Application Support/Worklog/Recovered/Store-<date>/` (nothing is ever deleted), then relaunches Worklog with a fresh store and either restores the backup you chose or, with iCloud sync on, downloads your data again. A backup picked from outside Worklog is copied in with its images embedded (Worklog asks once for access to the folder holding the backup's `Attachments`). The restore runs once, before anything is seeded: Replace when the new store is still empty, otherwise Merge after a safety backup; if it fails, a banner says so and the backup stays in the list. If Worklog quits or crashes during that restore, the next launch says “The last restore didn’t finish.” with **Restore…** (nothing is retried automatically). Whenever the app version, build, configuration, CloudKit environment or data model differs from the previous launch, Worklog first copies the store to `Recovered/PreOpen-<date>/` (the last two are kept), so a failed upgrade can be undone by hand.

**Export and import.**
- **JSON:** versioned (`formatVersion`, currently 2: profiles and each label's, tag's and session's profile), ISO-8601 dates, images optional as base64. Format-1 files from earlier versions still import: their sessions go to the home profile and their labels and tags become available in all profiles. Delete All Data and Replace with a file without profiles recreate the "Work" profile. Imported images are checked to be JPEG/PNG/HEIC of sane size.
- **CSV:** one file per session or per segment, RFC 4180 quoting, with the profile name as the last column. Values starting with `=`, `+`, `-`, `@`, tab or CR get a leading `'` so spreadsheet apps don't run them as formulas.
- **Importing:** importing an archive exported without images keeps the images already in the store (merge and replace). Archives now record which Mac controlled a running session (`ownerDeviceID`, optional).
- **Images you add** are limited to 100 MB files and 150 megapixels, then downscaled to 2048 px.

**Privacy.** Session titles, learnings, takeaways, notes, learning points, segment focus and image captions are stored with CloudKit encryption (`@Attribute(.allowsCloudEncryption)`), so they are encrypted with keys from the user's iCloud Keychain. Sign in with Apple identifiers live in the Keychain (data-protection keychain, this device only, when the app is signed with a team). Logs mark user content as private.

Signing out never deletes data. Neither does revoking Sign in with Apple; it only brings back the welcome screen.

## Known items to verify on a device

These can't be checked in CI and should be tried on real Macs before a release:

- **Toggling iCloud sync** reopens the same store file with and without CloudKit. Core Data may log "Forcing into Read Only mode store" or re-import on the next CloudKit launch; check that data survives switching sync off and on again (make a manual backup first).
- **Two Macs**: start sessions on both, let them sync, and check the handoff end time, the "running on another Mac" hint, and that sleeping the idle Mac doesn't pause the other Mac's session.
- **Profiles across Macs**: upgrade two Macs with existing data and check that one "Work" profile remains with all sessions (and keeps a name or colour you changed on either Mac); on a new Mac with sync, check that a "Work" profile deleted elsewhere doesn't come back; delete a profile on one Mac and check its sessions show in the home profile on the other.
- **Duplicate merge**: restore the same backup on two Macs with sync on and check that exactly one copy of each session remains on both.
- **Encrypted fields** appear as encrypted in the CloudKit Console and sync between Macs signed in to the same account.
- **Recovery**: corrupt a copy of the store (e.g. truncate `Worklog.store` while the app is quit) and walk through Recover… with a backup and with a fresh store.
- **Keychain**: with a team-signed build, sign in with Apple, quit, relaunch: the account should persist (items migrate from the legacy keychain on first read).
- **Move to iCloud Production**: on a copy of real data, walk through the checklist above; check the session and image counts, that `Recovered/Env-Development-…` holds the old store, and that a second Mac sees the data after **Use iCloud Production Data…**.
- **Single instance**: launch a second copy of the same build (e.g. from another folder): the first one comes to the front and the second quits.
