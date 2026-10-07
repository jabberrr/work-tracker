import Foundation
import SwiftData

@MainActor enum SeedData {
    static let didSeedDefaultsKey = "seed.didSeedDefaults"

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

    /// Merge duplicate WorkLabel/WorkTag objects sharing the same uuid (CloudKit can import a second copy of the
    /// seeded rows from another Mac). The survivor is the oldest createdAt; reassign all relationships; delete the rest.
    /// Also merges duplicate ended sessions sharing a uuid (same archive imported on two Macs; newest modifiedAt
    /// wins) and ends extra active sessions (keeps most recent startedAt active; others: endedAt = lastActivityDate).
    static func deduplicate(in context: ModelContext) {
        var changed = false
        changed = deduplicateLabels(in: context) || changed
        changed = deduplicateTags(in: context) || changed
        changed = deduplicateSessions(in: context) || changed
        changed = endExtraActiveSessions(in: context) || changed
        guard changed else { return }
        do {
            try context.save()
        } catch {
            Log.persistence.error("Deduplicate save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private static func deduplicateLabels(in context: ModelContext) -> Bool {
        let labels = (try? context.fetch(FetchDescriptor<WorkLabel>())) ?? []
        var changed = false
        for group in Dictionary(grouping: labels, by: \.uuid).values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for duplicate in sorted.dropFirst() {
                for session in duplicate.sessions ?? [] { session.label = survivor }
                for segment in duplicate.segments ?? [] { segment.label = survivor }
                for tag in duplicate.tags ?? [] { tag.label = survivor }
                context.delete(duplicate)
                changed = true
            }
            Log.persistence.info("Merged duplicate label \(survivor.name, privacy: .public)")
        }
        return changed
    }

    private static func deduplicateTags(in context: ModelContext) -> Bool {
        let tags = (try? context.fetch(FetchDescriptor<WorkTag>())) ?? []
        var changed = false
        for group in Dictionary(grouping: tags, by: \.uuid).values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let survivor = sorted[0]
            for duplicate in sorted.dropFirst() {
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
            Log.persistence.info("Merged duplicate tag \(survivor.name, privacy: .public)")
        }
        return changed
    }

    private static func deduplicateSessions(in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<WorkSession>(predicate: #Predicate<WorkSession> { $0.endedAt != nil })
        descriptor.propertiesToFetch = [\WorkSession.uuid, \WorkSession.modifiedAt]
        let sessions = (try? context.fetch(descriptor)) ?? []
        var changed = false
        for group in Dictionary(grouping: sessions, by: \.uuid).values where group.count > 1 {
            let sorted = group.sorted { $0.modifiedAt > $1.modifiedAt }
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
                changed = true
            }
        }
        return changed
    }

    private static func endExtraActiveSessions(in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt == nil },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        let actives = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDeleted }
        guard actives.count > 1 else { return false }
        for extra in actives.dropFirst() {
            SessionEditor.endSession(extra, at: extra.lastActivityDate)
            Log.persistence.info("Ended extra active session started \(extra.startedAt.ISO8601Format(), privacy: .public)")
        }
        return true
    }

    private static func replacing(_ old: WorkTag, with new: WorkTag, in tags: [WorkTag]) -> [WorkTag] {
        var result = tags.filter { $0 !== old }
        if !result.contains(where: { $0 === new }) { result.append(new) }
        return result
    }
}
