import Foundation
import SwiftData

/// Making a label/tag local to a profile while other profiles' sessions use it.
enum TaxonomyScopeImpact: Equatable {
    case none
    /// Making it local: other profiles use it; each gets its own copy.
    case copiesForOtherProfiles(profileNames: [String], sessionCount: Int)
}

/// Create / delete / merge / reorder labels and tags, and their profile scope (global or local to one profile).
///
/// Invariant kept by every operation here and by `SessionEditor.moveSession`: a session (its segments and learning
/// points) only references labels/tags offered in its profile (global, or local to that profile). An unassigned
/// session counts as its effective profile's (`ProfileOps.effectiveProfile(of:)`).
@MainActor enum TaxonomyOps {
    /// profile nil = global (existing callers). sortIndex = max+1 over ALL labels.
    @discardableResult
    static func createLabel(name: String, colorHex: String, symbolName: String, profile: WorkProfile? = nil,
                            in context: ModelContext) -> WorkLabel {
        let labels = (try? context.fetch(FetchDescriptor<WorkLabel>())) ?? []
        let nextIndex = (ModelLiveness.live(labels).map(\.sortIndex).max() ?? -1) + 1
        let trimmedName = name.trimmed
        let label = WorkLabel(name: trimmedName.isEmpty ? "New label" : trimmedName, colorHex: colorHex,
                              symbolName: symbolName.isBlank ? "circle.fill" : symbolName, sortIndex: nextIndex)
        context.insert(label)
        label.profile = ModelLiveness.live(profile)
        save(context)
        return label
    }

    /// Returns an existing non-archived same-name tag (case-insensitive, trimmed) offered in `profile` (profile nil:
    /// among GLOBAL tags only) instead of duplicating; else a new tag local to `profile` (nil = global).
    @discardableResult
    static func createTag(name: String, colorHex: String = "#8E8E93", label: WorkLabel? = nil,
                          profile: WorkProfile? = nil, in context: ModelContext) -> WorkTag {
        let trimmedName = name.trimmed
        let owner = ModelLiveness.live(profile)
        let scope = ProfileScope(profileID: owner?.uuid)
        let candidates = allTags(in: context).filter { tag in
            guard !tag.isArchived, sameName(tag.name, trimmedName) else { return false }
            return owner == nil ? isGlobal(tag) : scope.offers(tag)
        }
        // Prefer the profile's own tag over a global one with the same name.
        if let existing = candidates.first(where: { !isGlobal($0) }) ?? candidates.first {
            return existing
        }
        let tag = WorkTag(name: trimmedName.isEmpty ? "tag" : trimmedName, colorHex: colorHex)
        context.insert(tag)
        tag.label = ModelLiveness.live(label)
        tag.profile = owner
        save(context)
        return tag
    }

    /// Case-/diacritic-insensitive, trimmed name lookup. Prefers a non-archived tag.
    static func findTag(named name: String, in context: ModelContext) -> WorkTag? {
        let trimmedName = name.trimmed
        guard !trimmedName.isEmpty else { return nil }
        let matches = allTags(in: context).filter { sameName($0.name, trimmedName) }
        return matches.first(where: { !$0.isArchived }) ?? matches.first
    }

    /// Sessions/segments using `label` move to `reassignTo` (nil = become Unlabeled), then label is deleted.
    /// Tags scoped to `label` move to `reassignTo` (nil = become global).
    /// Clears settings.defaultLabelID (legacy) and every profile's `defaultLabelUUID` that pointed to it.
    /// Pick `reassignTo` from `reassignmentTargets(for:among:)` to keep the profile invariant.
    static func deleteLabel(_ label: WorkLabel, reassignTo: WorkLabel?, settings: AppSettings, in context: ModelContext) {
        let target: WorkLabel? = (reassignTo === label) ? nil : reassignTo
        for session in label.sessions ?? [] {
            session.label = target
            session.touch()
        }
        for segment in label.segments ?? [] {
            segment.label = target
            segment.session?.touch()
        }
        for tag in label.tags ?? [] {
            tag.label = target
        }
        if settings.defaultLabelID == label.uuid {
            settings.defaultLabelID = nil
        }
        for profile in ProfileOps.allProfiles(in: context) where profile.defaultLabelUUID == label.uuid {
            profile.defaultLabelUUID = nil
            profile.touch()
        }
        context.delete(label)
        save(context)
    }

    /// Everything using `source` moves to `target`; source is deleted. The default label (legacy setting and every
    /// profile's `defaultLabelUUID`) follows to `target`. Pick `target` from `reassignmentTargets(for:among:)`.
    static func mergeLabel(_ source: WorkLabel, into target: WorkLabel, settings: AppSettings, in context: ModelContext) {
        guard source !== target else { return }
        let pointedToSource = settings.defaultLabelID == source.uuid
        let sourceID = source.uuid
        let profilesPointing = ProfileOps.allProfiles(in: context).filter { $0.defaultLabelUUID == sourceID }
        deleteLabel(source, reassignTo: target, settings: settings, in: context)
        if pointedToSource {
            settings.defaultLabelID = target.uuid
        }
        if !profilesPointing.isEmpty {
            for profile in profilesPointing where ModelLiveness.isLive(profile) {
                profile.defaultLabelUUID = target.uuid
                profile.touch()
            }
            save(context)
        }
    }

    static func deleteTag(_ tag: WorkTag, in context: ModelContext) {
        for session in tag.sessions ?? [] { session.touch() }
        for segment in tag.segments ?? [] { segment.session?.touch() }
        for point in tag.learningPoints ?? [] { point.session?.touch() }
        context.delete(tag)
        save(context)
    }

    /// Replace `source` with `target` on all sessions/segments/learning points (no duplicates), delete source.
    static func mergeTag(_ source: WorkTag, into target: WorkTag, in context: ModelContext) {
        guard source !== target else { return }
        for session in source.sessions ?? [] {
            session.tagList = replacing(source, with: target, in: session.tagList)
            session.touch()
        }
        for segment in source.segments ?? [] {
            segment.tagList = replacing(source, with: target, in: segment.tagList)
            segment.session?.touch()
        }
        for point in source.learningPoints ?? [] {
            point.tagList = replacing(source, with: target, in: point.tagList)
            point.session?.touch()
        }
        context.delete(source)
        save(context)
    }

    static func reorderLabels(_ labels: [WorkLabel]) {
        for (index, label) in labels.enumerated() where label.sortIndex != index {
            label.sortIndex = index
        }
        if let context = labels.first?.modelContext {
            save(context)
        }
    }

    // MARK: - Profile scope

    /// What making `label` local to `profile` implies. profile nil (make global) → .none.
    static func scopeChangeImpact(of label: WorkLabel, to profile: WorkProfile?) -> TaxonomyScopeImpact {
        guard let profile = ModelLiveness.live(profile), ModelLiveness.isLive(label) else { return .none }
        let sessions = ModelLiveness.live(label.sessions ?? []) + (label.segments ?? []).compactMap { segment in
            ModelLiveness.isLive(segment) ? ModelLiveness.live(segment.session) : nil
        }
        return impact(of: sessions, outside: profile)
    }

    /// What making `tag` local to `profile` implies. profile nil (make global) → .none.
    static func scopeChangeImpact(of tag: WorkTag, to profile: WorkProfile?) -> TaxonomyScopeImpact {
        guard let profile = ModelLiveness.live(profile), ModelLiveness.isLive(tag) else { return .none }
        let fromSegments = (tag.segments ?? []).compactMap { segment in
            ModelLiveness.isLive(segment) ? ModelLiveness.live(segment.session) : nil
        }
        let fromPoints = (tag.learningPoints ?? []).compactMap { point in
            ModelLiveness.isLive(point) ? ModelLiveness.live(point.session) : nil
        }
        return impact(of: ModelLiveness.live(tag.sessions ?? []) + fromSegments + fromPoints, outside: profile)
    }

    /// profile nil = make global (always fine). A label that was local and is not archived then absorbs the
    /// non-archived same-name labels local to other profiles (`localDuplicatesMerged(byMakingGlobal:in:)`: their
    /// sessions, segments, tags and default-label choices move to it), so no profile shows the name twice.
    /// Non-nil: item.profile = profile FIRST (global and other profiles' tags whose parent it is lose that parent);
    /// then for every other profile Q whose sessions/segments use it, re-point those to equivalentLabel(for:in: Q);
    /// a Q.defaultLabelUUID pointing to the label follows to Q's copy. Unassigned sessions count as their effective
    /// profile's (`ProfileOps.effectiveProfile(of:)`); they are repaired first only where the repair is allowed
    /// (`SeedData.repairSessionProfilesIfAllowed`). Saves.
    static func setScope(of label: WorkLabel, to profile: WorkProfile?, in context: ModelContext) {
        guard ModelLiveness.isLive(label) else { return }
        guard let profile = ModelLiveness.live(profile) else {
            if ModelLiveness.live(label.profile) != nil {
                let duplicates = localDuplicatesMerged(byMakingGlobal: label, in: context)
                label.profile = nil
                for duplicate in duplicates { absorb(duplicate, into: label, in: context) }
            } else if label.profile != nil {
                label.profile = nil
            }
            save(context)
            return
        }
        SeedData.repairSessionProfilesIfAllowed(in: context)
        // Decide before re-scoping: an unassigned session's effective profile can depend on this label's owner.
        let segmentSessions = (label.segments ?? []).compactMap { segment in
            ModelLiveness.isLive(segment) ? ModelLiveness.live(segment.session) : nil
        }
        let sessionOwners = effectiveOwners(of: ModelLiveness.live(label.sessions ?? []) + segmentSessions)
        label.profile = profile
        // Global tags (and other profiles' tags) can't keep a parent only this profile offers.
        for tag in ModelLiveness.live(label.tags ?? []) where ModelLiveness.live(tag.profile) !== profile {
            tag.label = nil
        }

        var copies: [PersistentIdentifier: WorkLabel] = [:]
        func copy(in other: WorkProfile) -> WorkLabel {
            if let existing = copies[other.persistentModelID] { return existing }
            let made = equivalentLabel(for: label, in: other, in: context)
            copies[other.persistentModelID] = made
            return made
        }

        func otherProfile(of session: WorkSession?) -> WorkProfile? {
            guard let session = ModelLiveness.live(session),
                  let other = sessionOwners[session.persistentModelID], other !== profile else { return nil }
            return other
        }

        for session in ModelLiveness.live(label.sessions ?? []) {
            guard let other = otherProfile(of: session) else { continue }
            session.label = copy(in: other)
            session.touch()
        }
        for segment in ModelLiveness.live(label.segments ?? []) {
            guard let session = ModelLiveness.live(segment.session), let other = otherProfile(of: session) else { continue }
            segment.label = copy(in: other)
            session.touch()
        }
        let labelID = label.uuid
        for other in ProfileOps.allProfiles(in: context) where other !== profile && other.defaultLabelUUID == labelID {
            other.defaultLabelUUID = copy(in: other).uuid
            other.touch()
        }
        save(context)
    }

    /// profile nil = make global (always fine). A tag that was local: its parent label is cleared when that label is
    /// local (a global tag can't depend on one profile's label), and when the tag isn't archived it absorbs the
    /// non-archived same-name tags local to other profiles (`localDuplicatesMerged(byMakingGlobal:in:)`).
    /// Non-nil: item.profile = profile FIRST; then for every other profile Q whose sessions/segments/learning points
    /// use it, replace it there (no duplicates) with equivalentTag(for:in: Q). Unassigned sessions count as their
    /// effective profile's (see the label overload). Saves.
    static func setScope(of tag: WorkTag, to profile: WorkProfile?, in context: ModelContext) {
        guard ModelLiveness.isLive(tag) else { return }
        guard let profile = ModelLiveness.live(profile) else {
            if ModelLiveness.live(tag.profile) != nil {
                let duplicates = localDuplicatesMerged(byMakingGlobal: tag, in: context)
                tag.profile = nil
                if let parent = ModelLiveness.live(tag.label), ModelLiveness.live(parent.profile) != nil {
                    tag.label = nil
                }
                for duplicate in duplicates { absorb(duplicate, into: tag, in: context) }
            } else if tag.profile != nil {
                tag.profile = nil
            }
            save(context)
            return
        }
        SeedData.repairSessionProfilesIfAllowed(in: context)
        let fromSegments = (tag.segments ?? []).compactMap { segment in
            ModelLiveness.isLive(segment) ? ModelLiveness.live(segment.session) : nil
        }
        let fromPoints = (tag.learningPoints ?? []).compactMap { point in
            ModelLiveness.isLive(point) ? ModelLiveness.live(point.session) : nil
        }
        let sessionOwners = effectiveOwners(of: ModelLiveness.live(tag.sessions ?? []) + fromSegments + fromPoints)
        tag.profile = profile

        var copies: [PersistentIdentifier: WorkTag] = [:]
        func copy(in other: WorkProfile) -> WorkTag {
            if let existing = copies[other.persistentModelID] { return existing }
            let made = equivalentTag(for: tag, in: other, in: context)
            copies[other.persistentModelID] = made
            return made
        }
        func otherProfile(of session: WorkSession?) -> WorkProfile? {
            guard let session = ModelLiveness.live(session),
                  let other = sessionOwners[session.persistentModelID], other !== profile else { return nil }
            return other
        }

        for session in ModelLiveness.live(tag.sessions ?? []) {
            guard let other = otherProfile(of: session) else { continue }
            session.tagList = replacing(tag, with: copy(in: other), in: session.tagList)
            session.touch()
        }
        for segment in ModelLiveness.live(tag.segments ?? []) {
            guard let other = otherProfile(of: segment.session) else { continue }
            segment.tagList = replacing(tag, with: copy(in: other), in: segment.tagList)
            segment.session?.touch()
        }
        for point in ModelLiveness.live(tag.learningPoints ?? []) {
            guard let other = otherProfile(of: point.session) else { continue }
            point.tagList = replacing(tag, with: copy(in: other), in: point.tagList)
            point.session?.touch()
        }
        save(context)
    }

    /// Same-name (trimmed, case/diacritic-insensitive, prefer non-archived) label offered in `profile`, excluding
    /// `label` itself when it's not offered there; else inserts a local copy in `profile` (name, colorHex, symbolName,
    /// sortIndex, archived state). Does not save.
    static func equivalentLabel(for label: WorkLabel, in profile: WorkProfile, in context: ModelContext) -> WorkLabel {
        if let existing = existingEquivalentLabel(for: label, in: profile, in: context) { return existing }
        let copy = WorkLabel(name: label.name, colorHex: label.colorHex, symbolName: label.symbolName,
                             sortIndex: label.sortIndex)
        context.insert(copy)
        copy.isArchived = label.isArchived
        copy.profile = profile
        return copy
    }

    /// Same-name tag offered in `profile` (as `equivalentLabel`); else inserts a local copy in `profile` (name,
    /// colorHex, archived state; keeps the `label` parent only if that parent is offered in `profile`). Does not save.
    static func equivalentTag(for tag: WorkTag, in profile: WorkProfile, in context: ModelContext) -> WorkTag {
        if let existing = existingEquivalentTag(for: tag, in: profile, in: context) { return existing }
        let copy = WorkTag(name: tag.name, colorHex: tag.colorHex)
        context.insert(copy)
        copy.isArchived = tag.isArchived
        copy.profile = profile
        if let parent = ModelLiveness.live(tag.label), ProfileScope(profileID: profile.uuid).offers(parent) {
            copy.label = parent
        }
        return copy
    }

    /// The label `equivalentLabel` would return without inserting anything: `label` itself when offered in
    /// `profile`, else a same-name label offered there (non-archived preferred), else nil.
    static func existingEquivalentLabel(for label: WorkLabel, in profile: WorkProfile,
                                        in context: ModelContext) -> WorkLabel? {
        let scope = ProfileScope(profileID: profile.uuid)
        if scope.offers(label) { return label }
        let all = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkLabel>(
            sortBy: [SortDescriptor(\WorkLabel.sortIndex)]))) ?? [])
        let matches = all.filter { $0 !== label && scope.offers($0) && sameName($0.name, label.name) }
        return matches.first(where: { !$0.isArchived }) ?? matches.first
    }

    /// The tag `equivalentTag` would return without inserting anything (see `existingEquivalentLabel`).
    static func existingEquivalentTag(for tag: WorkTag, in profile: WorkProfile, in context: ModelContext) -> WorkTag? {
        let scope = ProfileScope(profileID: profile.uuid)
        if scope.offers(tag) { return tag }
        let matches = allTags(in: context).filter { $0 !== tag && scope.offers($0) && sameName($0.name, tag.name) }
        return matches.first(where: { !$0.isArchived }) ?? matches.first
    }

    /// Replaces every label/tag referenced by `session`, its segments and its learning points that `profile` doesn't
    /// offer with equivalentLabel/equivalentTag (a same-name item offered there, else a local copy; one copy per item,
    /// no duplicate tags). Keeps the invariant whenever a session lands in a profile: `SessionEditor.moveSession`,
    /// import, and the assignment of an unassigned session. Never touches modifiedAt; does not save.
    /// Returns true when anything changed.
    @discardableResult
    static func conformTaxonomy(of session: WorkSession, to profile: WorkProfile, in context: ModelContext) -> Bool {
        guard ModelLiveness.isLive(session), ModelLiveness.isLive(profile) else { return false }
        let scope = ProfileScope(profileID: profile.uuid)
        var changed = false

        var labelMap: [PersistentIdentifier: WorkLabel] = [:]
        var tagMap: [PersistentIdentifier: WorkTag] = [:]
        func mappedLabel(_ label: WorkLabel) -> WorkLabel {
            if scope.offers(label) { return label }
            if let known = labelMap[label.persistentModelID] { return known }
            let equivalent = equivalentLabel(for: label, in: profile, in: context)
            labelMap[label.persistentModelID] = equivalent
            return equivalent
        }
        func mappedTags(_ tags: [WorkTag]) -> [WorkTag] {
            var result: [WorkTag] = []
            for tag in ModelLiveness.live(tags) {
                let target: WorkTag
                if scope.offers(tag) {
                    target = tag
                } else if let known = tagMap[tag.persistentModelID] {
                    target = known
                } else {
                    target = equivalentTag(for: tag, in: profile, in: context)
                    tagMap[tag.persistentModelID] = target
                }
                if !result.contains(where: { $0 === target }) { result.append(target) }
            }
            return result
        }
        func needsMapping(_ tags: [WorkTag]) -> Bool {
            ModelLiveness.live(tags).contains { !scope.offers($0) }
        }

        if let label = ModelLiveness.live(session.label), !scope.offers(label) {
            session.label = mappedLabel(label)
            changed = true
        }
        if needsMapping(session.tagList) {
            session.tagList = mappedTags(session.tagList)
            changed = true
        }
        for segment in session.sortedSegments where !segment.isDeleted {
            if let label = ModelLiveness.live(segment.label), !scope.offers(label) {
                segment.label = mappedLabel(label)
                changed = true
            }
            if needsMapping(segment.tagList) {
                segment.tagList = mappedTags(segment.tagList)
                changed = true
            }
        }
        for point in ModelLiveness.live(session.learningPoints ?? []) where needsMapping(point.tagList) {
            point.tagList = mappedTags(point.tagList)
            changed = true
        }
        return changed
    }

    /// The non-archived labels, local to some profile, with `label`'s name (trimmed, case/diacritic-insensitive) that
    /// making `label` global merges into it. Empty when `label` is archived or already global. For confirm texts.
    static func localDuplicatesMerged(byMakingGlobal label: WorkLabel, in context: ModelContext) -> [WorkLabel] {
        guard ModelLiveness.isLive(label), !label.isArchived, ModelLiveness.live(label.profile) != nil else { return [] }
        let all = ModelLiveness.live((try? context.fetch(FetchDescriptor<WorkLabel>())) ?? [])
        return all.filter { candidate in
            candidate !== label && !candidate.isArchived && ModelLiveness.live(candidate.profile) != nil
                && sameName(candidate.name, label.name)
        }
    }

    /// The non-archived tags, local to some profile, with `tag`'s name that making `tag` global merges into it.
    static func localDuplicatesMerged(byMakingGlobal tag: WorkTag, in context: ModelContext) -> [WorkTag] {
        guard ModelLiveness.isLive(tag), !tag.isArchived, ModelLiveness.live(tag.profile) != nil else { return [] }
        return allTags(in: context).filter { candidate in
            candidate !== tag && !candidate.isArchived && ModelLiveness.live(candidate.profile) != nil
                && sameName(candidate.name, tag.name)
        }
    }

    /// Everything using `source` (sessions, segments, child tags, every profile's default-label choice) moves to
    /// `target`; source is deleted. Sessions are touched. Does not save. (Merging without the legacy setting, which only
    /// matters while no profile exists.)
    static func absorb(_ source: WorkLabel, into target: WorkLabel, in context: ModelContext) {
        guard source !== target, ModelLiveness.isLive(source), ModelLiveness.isLive(target) else { return }
        for session in ModelLiveness.live(source.sessions ?? []) {
            session.label = target
            session.touch()
        }
        for segment in ModelLiveness.live(source.segments ?? []) {
            segment.label = target
            segment.session?.touch()
        }
        for tag in ModelLiveness.live(source.tags ?? []) {
            tag.label = target
        }
        let sourceID = source.uuid
        for profile in ProfileOps.allProfiles(in: context) where profile.defaultLabelUUID == sourceID {
            profile.defaultLabelUUID = target.uuid
            profile.touch()
        }
        context.delete(source)
    }

    /// Replaces `source` with `target` on all sessions/segments/learning points (no duplicates, sessions touched) and
    /// deletes source. Does not save.
    static func absorb(_ source: WorkTag, into target: WorkTag, in context: ModelContext) {
        guard source !== target, ModelLiveness.isLive(source), ModelLiveness.isLive(target) else { return }
        for session in ModelLiveness.live(source.sessions ?? []) {
            session.tagList = replacing(source, with: target, in: session.tagList)
            session.touch()
        }
        for segment in ModelLiveness.live(source.segments ?? []) {
            segment.tagList = replacing(source, with: target, in: segment.tagList)
            segment.session?.touch()
        }
        for point in ModelLiveness.live(source.learningPoints ?? []) {
            point.tagList = replacing(source, with: target, in: point.tagList)
            point.session?.touch()
        }
        if target.label == nil, let parent = ModelLiveness.live(source.label),
           ProfileScope(profileID: ModelLiveness.live(target.profile)?.uuid).offers(parent),
           ModelLiveness.live(target.profile) != nil || ModelLiveness.live(parent.profile) == nil {
            target.label = parent   // only a parent offered wherever the target is (a global tag needs a global one)
        }
        context.delete(source)
    }

    /// Delete/merge targets keeping the invariant: global source → global; local(P) → global + local(P).
    /// Excludes the source; non-archived only.
    static func reassignmentTargets(for label: WorkLabel, among labels: [WorkLabel]) -> [WorkLabel] {
        let owner = ModelLiveness.isLive(label) ? ModelLiveness.live(label.profile) : nil
        return ModelLiveness.live(labels).filter { candidate in
            guard candidate !== label, !candidate.isArchived else { return false }
            guard let candidateOwner = ModelLiveness.live(candidate.profile) else { return true }
            return owner != nil && candidateOwner === owner
        }
    }

    /// Delete/merge targets keeping the invariant: global source → global; local(P) → global + local(P).
    /// Excludes the source; non-archived only.
    static func mergeTargets(for tag: WorkTag, among tags: [WorkTag]) -> [WorkTag] {
        let owner = ModelLiveness.isLive(tag) ? ModelLiveness.live(tag.profile) : nil
        return ModelLiveness.live(tags).filter { candidate in
            guard candidate !== tag, !candidate.isArchived else { return false }
            guard let candidateOwner = ModelLiveness.live(candidate.profile) else { return true }
            return owner != nil && candidateOwner === owner
        }
    }

    // MARK: - Private

    private static func allTags(in context: ModelContext) -> [WorkTag] {
        let descriptor = FetchDescriptor<WorkTag>(sortBy: [SortDescriptor(\WorkTag.createdAt)])
        return ModelLiveness.live((try? context.fetch(descriptor)) ?? [])
    }

    /// Effective profile (`ProfileOps.effectiveProfile(of:)`) of each live session, by persistentModelID.
    private static func effectiveOwners(of sessions: [WorkSession]) -> [PersistentIdentifier: WorkProfile] {
        var owners: [PersistentIdentifier: WorkProfile] = [:]
        for session in sessions where ModelLiveness.isLive(session) && owners[session.persistentModelID] == nil {
            if let owner = ProfileOps.effectiveProfile(of: session) {
                owners[session.persistentModelID] = owner
            }
        }
        return owners
    }

    /// Global: no live profile (nil, or its profile was deleted).
    private static func isGlobal(_ tag: WorkTag) -> Bool {
        ModelLiveness.live(tag.profile) == nil
    }

    /// Profiles other than `profile` among the sessions' (live) profiles → .copiesForOtherProfiles, else .none.
    private static func impact(of sessions: [WorkSession], outside profile: WorkProfile) -> TaxonomyScopeImpact {
        var seenSessions = Set<PersistentIdentifier>()
        var others: [WorkProfile] = []
        for session in sessions {
            guard let owner = ProfileOps.effectiveProfile(of: session), owner !== profile else { continue }
            guard seenSessions.insert(session.persistentModelID).inserted else { continue }
            if !others.contains(where: { $0 === owner }) { others.append(owner) }
        }
        guard !others.isEmpty else { return .none }
        let ordered = others.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        return .copiesForOtherProfiles(profileNames: ordered.map(\.displayName), sessionCount: seenSessions.count)
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmed.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func replacing(_ source: WorkTag, with target: WorkTag, in tags: [WorkTag]) -> [WorkTag] {
        var result = tags.filter { $0 !== source }
        if !result.contains(where: { $0 === target }) { result.append(target) }
        return result
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            Log.persistence.error("TaxonomyOps save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
