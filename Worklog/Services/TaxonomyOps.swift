import Foundation
import SwiftData

/// Create / delete / merge / reorder labels and tags.
@MainActor enum TaxonomyOps {
    /// sortIndex = max+1.
    @discardableResult
    static func createLabel(name: String, colorHex: String, symbolName: String, in context: ModelContext) -> WorkLabel {
        let labels = (try? context.fetch(FetchDescriptor<WorkLabel>())) ?? []
        let nextIndex = (labels.map(\.sortIndex).max() ?? -1) + 1
        let trimmedName = name.trimmed
        let label = WorkLabel(name: trimmedName.isEmpty ? "New label" : trimmedName, colorHex: colorHex,
                              symbolName: symbolName.isBlank ? "circle.fill" : symbolName, sortIndex: nextIndex)
        context.insert(label)
        save(context)
        return label
    }

    /// Returns an existing non-archived tag with the same name (case-insensitive, trimmed) instead of duplicating.
    @discardableResult
    static func createTag(name: String, colorHex: String = "#8E8E93", label: WorkLabel? = nil,
                          in context: ModelContext) -> WorkTag {
        let trimmedName = name.trimmed
        if let existing = allTags(in: context).first(where: { !$0.isArchived && sameName($0.name, trimmedName) }) {
            return existing
        }
        let tag = WorkTag(name: trimmedName.isEmpty ? "tag" : trimmedName, colorHex: colorHex)
        context.insert(tag)
        tag.label = label
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
    /// Clears settings.defaultLabelID if it pointed to it (caller passes settings).
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
        context.delete(label)
        save(context)
    }

    /// Everything using `source` moves to `target`; source is deleted. The default label follows to `target`.
    static func mergeLabel(_ source: WorkLabel, into target: WorkLabel, settings: AppSettings, in context: ModelContext) {
        guard source !== target else { return }
        let pointedToSource = settings.defaultLabelID == source.uuid
        deleteLabel(source, reassignTo: target, settings: settings, in: context)
        if pointedToSource {
            settings.defaultLabelID = target.uuid
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

    // MARK: - Private

    private static func allTags(in context: ModelContext) -> [WorkTag] {
        let descriptor = FetchDescriptor<WorkTag>(sortBy: [SortDescriptor(\WorkTag.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
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
