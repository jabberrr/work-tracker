import Foundation
import SwiftData

@MainActor enum SeedData {
    static let didSeedDefaultsKey = "seed.didSeedDefaults"
    /// instanceID (uuidString) of a default profile created before the first iCloud import (see `ensureProfiles`).
    static let provisionalDefaultProfileKey = "profiles.provisionalDefaultInstanceID"
    /// UserDefaults (`settings.defaults`) flag: the legacy `settings.defaultLabelID` was offered to the default profile.
    static let legacyDefaultLabelCopiedKey = "profiles.legacyDefaultLabelCopied"
    /// True in CloudKit mode (set by AppServices before any data setup): unassigned sessions are then never repaired in
    /// the background — they are shown in their effective profile (`ProfileOps.effectiveProfile(of:)`) and assigned
    /// only when the user edits them. A background write could overwrite the real profile of a session whose profile
    /// relationship another Mac hasn't finished syncing, or that an older app version still edits. Local-only stores
    /// keep repairing (false: the default, also for previews and tests).
    static var isSessionProfileRepairDisplayOnly = false

    /// The ONE entry point for the background repair of unassigned sessions (launch, dedupe, import, scope changes):
    /// `ProfileOps.repairSessionProfiles` in a local-only store; a no-op returning 0 when
    /// `isSessionProfileRepairDisplayOnly`. Does not save.
    @discardableResult
    static func repairSessionProfilesIfAllowed(in context: ModelContext) -> Int {
        guard !isSessionProfileRepairDisplayOnly else { return 0 }
        return ProfileOps.repairSessionProfiles(in: context)
    }

    /// Default labels: name, hex, SF Symbol, fixed uuid (fixed so copies created on two Macs can be merged).
    static let defaultLabels: [(name: String, hex: String, symbol: String, uuid: String)] = [
        ("Deep work", "#5B8DEF", "brain.head.profile", "6F1C0E10-0000-4000-8000-000000000001"),
        ("Meetings", "#F2994A", "person.2.fill", "6F1C0E10-0000-4000-8000-000000000002"),
        ("Admin & email", "#9B9B9B", "tray.full.fill", "6F1C0E10-0000-4000-8000-000000000003"),
        ("Learning", "#27AE60", "book.fill", "6F1C0E10-0000-4000-8000-000000000004"),
        ("Planning", "#9B51E0", "list.bullet.clipboard", "6F1C0E10-0000-4000-8000-000000000005"),
    ]

    /// Default global tags (#8E8E93).
    static let defaultTags: [(name: String, uuid: String)] = [
        ("coding", "6F1C0E10-0000-4000-8000-000000000101"),
        ("writing", "6F1C0E10-0000-4000-8000-000000000102"),
        ("review", "6F1C0E10-0000-4000-8000-000000000103"),
        ("research", "6F1C0E10-0000-4000-8000-000000000104"),
    ]

    /// If no WorkLabel exists and UserDefaults "seed.didSeedDefaults" is false: insert default labels/tags with the
    /// FIXED uuids, set the flag, save. ("Restore defaults" resets the flag first, then calls this.)
    static func seedIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedDefaultsKey) else { return }
        let labelCount = (try? context.fetchCount(FetchDescriptor<WorkLabel>())) ?? 0
        guard labelCount == 0 else {
            // Labels already exist (e.g. synced from another Mac); never seed on top of them.
            defaults.set(true, forKey: didSeedDefaultsKey)
            return
        }
        insertDefaults(into: context)
        do {
            try context.save()
            defaults.set(true, forKey: didSeedDefaultsKey)
        } catch {
            Log.persistence.error("Seeding failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Inserts the default labels and tags whose uuids are not already present. Does not save.
    /// (CORE helper, also used by PreviewData.)
    static func insertDefaults(into context: ModelContext) {
        let existingLabels = Set(((try? context.fetch(FetchDescriptor<WorkLabel>())) ?? []).map(\.uuid))
        let existingTags = Set(((try? context.fetch(FetchDescriptor<WorkTag>())) ?? []).map(\.uuid))
        for (index, item) in defaultLabels.enumerated() {
            guard let uuid = UUID(uuidString: item.uuid), !existingLabels.contains(uuid) else { continue }
            context.insert(WorkLabel(name: item.name, colorHex: item.hex, symbolName: item.symbol,
                                     sortIndex: index, uuid: uuid))
        }
        for item in defaultTags {
            guard let uuid = UUID(uuidString: item.uuid), !existingTags.contains(uuid) else { continue }
            context.insert(WorkTag(name: item.name, colorHex: "#8E8E93", uuid: uuid))
        }
    }

    // MARK: - Profiles

    /// Launch step (AppServices, after pending-restore/seeding, before deduplicate):
    /// 1. If no WorkProfile exists: ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: settings.defaultLabelID).
    ///    If `provisional` (CloudKit on and the first iCloud import hasn't completed yet), store the new profile's
    ///    instanceID under `provisionalDefaultProfileKey` (in `settings.defaults`).
    /// 2. Once (`legacyDefaultLabelCopiedKey`): when the default profile already existed (synced from another Mac) and
    ///    has no default label, the legacy `settings.defaultLabelID` is copied into it.
    /// 3. repairSessionProfilesIfAllowed (skipped in CloudKit mode). Saves if anything changed. Never touches a
    ///    session's modifiedAt.
    static func ensureProfiles(in context: ModelContext, settings: AppSettings, provisional: Bool = false) {
        var changed = false
        let created = ProfileOps.ensureDefaultProfile(legacyDefaultLabelID: settings.defaultLabelID, in: context)
        if let created {
            changed = true
            if provisional {
                settings.defaults.set(created.instanceID.uuidString, forKey: provisionalDefaultProfileKey)
            }
        }
        if !settings.defaults.bool(forKey: legacyDefaultLabelCopiedKey) {
            if created == nil, let legacy = settings.defaultLabelID,
               let work = ProfileOps.profile(withID: ProfileOps.defaultProfileUUID, in: context),
               work.defaultLabelUUID == nil {
                work.defaultLabelUUID = legacy
                changed = true
            }
            settings.defaults.set(true, forKey: legacyDefaultLabelCopiedKey)
        }
        if repairSessionProfilesIfAllowed(in: context) > 0 {
            changed = true
        }
        guard changed else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("Profile setup save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After the first iCloud import: if the profile whose instanceID == stored key still exists, has no sessions and
    /// no local labels/tags, and another non-archived profile exists → delete it. Always clears the key once evaluated.
    /// (Prevents a new Mac from resurrecting a "Work" profile the user deleted elsewhere.)
    static func discardProvisionalDefaultProfile(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: provisionalDefaultProfileKey) else { return }
        defaults.removeObject(forKey: provisionalDefaultProfileKey)
        guard let instanceID = UUID(uuidString: raw) else { return }
        let all = ProfileOps.allProfiles(in: context)
        guard let provisional = all.first(where: { $0.instanceID == instanceID }) else { return }
        guard ModelLiveness.live(provisional.sessions ?? []).isEmpty,
              ModelLiveness.live(provisional.labels ?? []).isEmpty,
              ModelLiveness.live(provisional.tags ?? []).isEmpty,
              all.contains(where: { $0 !== provisional && !$0.isArchived }) else { return }
        context.delete(provisional)
        do {
            try context.save()
            Log.persistence.info("Removed the provisional default profile")
        } catch {
            Log.persistence.error("Removing the provisional profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Deduplicate

    /// Merge duplicate WorkLabel/WorkTag objects sharing the same uuid (CloudKit can import a second copy of the
    /// seeded rows from another Mac) and duplicate ended sessions sharing a uuid (same archive imported on two Macs;
    /// notes, learning points and images only the deleted copy has move to the survivor first — `absorbChildren`).
    ///
    /// The survivor must be the SAME row on every Mac, otherwise each Mac deletes the other's copy and both vanish after
    /// sync. So the order only uses synced values: labels/tags by (createdAt asc, instanceID asc), sessions by
    /// (modifiedAt desc, instanceID asc). When the two best candidates can't be told apart (identical keys — e.g. rows
    /// from before `instanceID` existed, which all share the migration default) nothing is deleted: a visible duplicate
    /// is better than losing both copies.
    ///
    /// Extra running sessions are NOT ended here: `SessionEngine.reconcile()` (always called right after) ends them at
    /// the handoff time and tells the user.
    ///
    /// Order: profiles (identity by the label rules; the attributes of the most recently modified copy win; sessions,
    /// labels and tags of a duplicate move to the survivor) → labels → tags (copies scoped to different profiles: the
    /// survivor becomes global) → sessions → `repairSessionProfilesIfAllowed` (skipped in CloudKit mode) → save if
    /// anything changed. Nothing here touches a session's modifiedAt.
    static func deduplicate(in context: ModelContext) {
        var changed = false
        changed = deduplicateProfiles(in: context) || changed
        changed = deduplicateLabels(in: context) || changed
        changed = deduplicateTags(in: context) || changed
        changed = deduplicateSessions(in: context) || changed
        changed = repairSessionProfilesIfAllowed(in: context) > 0 || changed
        guard changed else { return }
        ProfileOps.invalidateHomeProfileCache()
        do {
            try context.save()
        } catch {
            Log.persistence.error("Deduplicate save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ordering (pure; unit-tested)

    /// Labels/tags: oldest createdAt first; ties broken by instanceID. `nil` = indistinguishable.
    nonisolated static func taxonomyPrecedes(createdAt lhsDate: Date, instanceID lhsID: UUID,
                                             _ rhsDate: Date, _ rhsID: UUID) -> Bool? {
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhsID != rhsID { return lhsID.uuidString < rhsID.uuidString }
        return nil
    }

    /// Sessions: newest modifiedAt first; ties broken by instanceID. `nil` = indistinguishable.
    nonisolated static func sessionPrecedes(modifiedAt lhsDate: Date, instanceID lhsID: UUID,
                                            _ rhsDate: Date, _ rhsID: UUID) -> Bool? {
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhsID != rhsID { return lhsID.uuidString < rhsID.uuidString }
        return nil
    }

    /// Sorts `group` with `precedes` and returns (survivor, duplicates), or nil when the two best candidates tie.
    private static func pickSurvivor<T>(_ group: [T], precedes: (T, T) -> Bool?) -> (survivor: T, duplicates: [T])? {
        let sorted = group.sorted { precedes($0, $1) ?? false }
        guard sorted.count > 1 else { return nil }
        guard precedes(sorted[0], sorted[1]) == true else { return nil }
        return (sorted[0], Array(sorted.dropFirst()))
    }

    // MARK: - Private

    private static func deduplicateProfiles(in context: ModelContext) -> Bool {
        let profiles = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkProfile>())) ?? [])
        var changed = false
        for group in Dictionary(grouping: profiles, by: \.uuid).values where group.count > 1 {
            guard let pick = pickSurvivor(group, precedes: {
                taxonomyPrecedes(createdAt: $0.createdAt, instanceID: $0.instanceID, $1.createdAt, $1.instanceID)
            }) else {
                Log.persistence.info("Skipped merging \(group.count) indistinguishable profile copies")
                continue
            }
            let survivor = pick.survivor
            // Identity (row) = oldest copy; attributes = most recently modified copy (same choice on every Mac).
            let newest = group.sorted {
                sessionPrecedes(modifiedAt: $0.modifiedAt, instanceID: $0.instanceID, $1.modifiedAt, $1.instanceID)
                    ?? false
            }.first ?? survivor
            if newest !== survivor {
                survivor.name = newest.name
                survivor.colorHex = newest.colorHex
                survivor.symbolName = newest.symbolName
                survivor.sortIndex = newest.sortIndex
                survivor.isArchived = newest.isArchived
                if let labelID = newest.defaultLabelUUID { survivor.defaultLabelUUID = labelID }
                survivor.modifiedAt = newest.modifiedAt
            }
            for duplicate in pick.duplicates {
                for session in duplicate.sessions ?? [] where !session.isDeleted { session.profile = survivor }
                for label in duplicate.labels ?? [] where !label.isDeleted { label.profile = survivor }
                for tag in duplicate.tags ?? [] where !tag.isDeleted { tag.profile = survivor }
                if survivor.defaultLabelUUID == nil, let labelID = duplicate.defaultLabelUUID {
                    survivor.defaultLabelUUID = labelID
                }
                context.delete(duplicate)
                changed = true
            }
            Log.persistence.info("Merged duplicate profile \(survivor.name, privacy: .private)")
        }
        if changed {
            ProfileOps.ensureNonArchivedProfile(in: context)
        }
        return changed
    }

    private static func deduplicateLabels(in context: ModelContext) -> Bool {
        let labels = ((try? context.fetch(FetchDescriptor<WorkLabel>())) ?? []).filter { !$0.isDeleted }
        var changed = false
        for group in Dictionary(grouping: labels, by: \.uuid).values where group.count > 1 {
            guard let pick = pickSurvivor(group, precedes: {
                taxonomyPrecedes(createdAt: $0.createdAt, instanceID: $0.instanceID, $1.createdAt, $1.instanceID)
            }) else {
                Log.persistence.info("Skipped merging \(group.count) indistinguishable label copies")
                continue
            }
            let survivor = pick.survivor
            // Copies scoped differently (another profile, or global): the survivor becomes global so every session
            // that used a copy still sees it offered.
            let survivorOwner = ModelLiveness.live(survivor.profile)
            if group.contains(where: { ModelLiveness.live($0.profile) !== survivorOwner }) {
                survivor.profile = nil
            }
            for duplicate in pick.duplicates {
                for session in duplicate.sessions ?? [] { session.label = survivor }
                for segment in duplicate.segments ?? [] { segment.label = survivor }
                for tag in duplicate.tags ?? [] { tag.label = survivor }
                context.delete(duplicate)
                changed = true
            }
            Log.persistence.info("Merged duplicate label \(survivor.name, privacy: .private)")
        }
        return changed
    }

    private static func deduplicateTags(in context: ModelContext) -> Bool {
        let tags = ((try? context.fetch(FetchDescriptor<WorkTag>())) ?? []).filter { !$0.isDeleted }
        var changed = false
        for group in Dictionary(grouping: tags, by: \.uuid).values where group.count > 1 {
            guard let pick = pickSurvivor(group, precedes: {
                taxonomyPrecedes(createdAt: $0.createdAt, instanceID: $0.instanceID, $1.createdAt, $1.instanceID)
            }) else {
                Log.persistence.info("Skipped merging \(group.count) indistinguishable tag copies")
                continue
            }
            let survivor = pick.survivor
            // Copies scoped differently: the survivor becomes global (see deduplicateLabels).
            let survivorOwner = ModelLiveness.live(survivor.profile)
            if group.contains(where: { ModelLiveness.live($0.profile) !== survivorOwner }) {
                survivor.profile = nil
            }
            for duplicate in pick.duplicates {
                for session in duplicate.sessions ?? [] {
                    session.tagList = replacing(duplicate, with: survivor, in: session.tagList)
                }
                for segment in duplicate.segments ?? [] {
                    segment.tagList = replacing(duplicate, with: survivor, in: segment.tagList)
                }
                for point in duplicate.learningPoints ?? [] {
                    point.tagList = replacing(duplicate, with: survivor, in: point.tagList)
                }
                if survivor.label == nil, let parent = duplicate.label { survivor.label = parent }
                context.delete(duplicate)
                changed = true
            }
            Log.persistence.info("Merged duplicate tag \(survivor.name, privacy: .private)")
        }
        return changed
    }

    private static func deduplicateSessions(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.endedAt != nil })
        let sessions = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDeleted }
        var changed = false
        for group in Dictionary(grouping: sessions, by: \.uuid).values where group.count > 1 {
            guard let pick = pickSurvivor(group, precedes: {
                sessionPrecedes(modifiedAt: $0.modifiedAt, instanceID: $0.instanceID, $1.modifiedAt, $1.instanceID)
            }) else {
                Log.persistence.info("Skipped merging \(group.count) indistinguishable session copies")
                continue
            }
            for duplicate in pick.duplicates {
                // H4: the copy being deleted may hold children the survivor lacks (an image or note added on one
                // Mac before the copies met). Move them over first; the cascade would delete them otherwise.
                absorbChildren(of: duplicate, into: pick.survivor)
                context.delete(duplicate)
                changed = true
            }
        }
        return changed
    }

    /// Re-parents to `survivor` the notes, learning points and images of `duplicate` whose uuid the survivor doesn't
    /// have, and fills image bytes the survivor's same-uuid attachment is missing. Never touches either session's
    /// modifiedAt. Does not save. (Internal for tests.)
    static func absorbChildren(of duplicate: WorkSession, into survivor: WorkSession) {
        var survivorAttachments: [UUID: Attachment] = [:]
        for attachment in ModelLiveness.live(survivor.attachments ?? []) where survivorAttachments[attachment.uuid] == nil {
            survivorAttachments[attachment.uuid] = attachment
        }
        for attachment in ModelLiveness.live(duplicate.attachments ?? []) {
            if let existing = survivorAttachments[attachment.uuid] {
                if existing.data == nil, let data = attachment.data {
                    existing.data = data
                    existing.thumbnailData = attachment.thumbnailData ?? existing.thumbnailData
                    existing.uti = attachment.uti
                    existing.pixelWidth = attachment.pixelWidth
                    existing.pixelHeight = attachment.pixelHeight
                } else if existing.thumbnailData == nil, let thumb = attachment.thumbnailData {
                    existing.thumbnailData = thumb
                }
            } else {
                attachment.session = survivor
                survivorAttachments[attachment.uuid] = attachment
            }
        }

        var noteIDs = Set(ModelLiveness.live(survivor.notes ?? []).map(\.uuid))
        for note in ModelLiveness.live(duplicate.notes ?? []) where !noteIDs.contains(note.uuid) {
            note.session = survivor
            note.segment = survivor.segment(containing: note.createdAt)
            noteIDs.insert(note.uuid)
        }

        var pointIDs = Set(ModelLiveness.live(survivor.learningPoints ?? []).map(\.uuid))
        for point in ModelLiveness.live(duplicate.learningPoints ?? []) where !pointIDs.contains(point.uuid) {
            point.session = survivor
            pointIDs.insert(point.uuid)
        }
    }

    private static func replacing(_ old: WorkTag, with new: WorkTag, in tags: [WorkTag]) -> [WorkTag] {
        var result = tags.filter { $0 !== old }
        if !result.contains(where: { $0 === new }) { result.append(new) }
        return result
    }
}
