import Foundation
import SwiftData

/// A profile ("Work", "Personal", …): an independent set of sessions plus the labels and tags local to it.
/// Labels and tags with `profile == nil` are global (offered in every profile). See ARCHITECTURE §12.
///
/// CloudKit: every attribute has a default, the relationships are optional and their inverses are declared on the
/// to-one side (`WorkSession.profile`, `WorkLabel.profile`, `WorkTag.profile`), no unique constraints.
@Model
final class WorkProfile {
    var uuid: UUID = UUID()
    /// New on every insert; deterministic dedupe tie-break (same as WorkLabel/WorkTag).
    var instanceID: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#5B8DEF"
    var symbolName: String = "briefcase.fill"
    var sortIndex: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    /// uuid of the WorkLabel new sessions in this profile start with; nil = first offered label.
    var defaultLabelUUID: UUID? = nil

    var sessions: [WorkSession]? = []
    /// Labels local to this profile (global labels have profile == nil).
    var labels: [WorkLabel]? = []
    /// Tags local to this profile.
    var tags: [WorkTag]? = []

    init(name: String, colorHex: String = "#5B8DEF", symbolName: String = "briefcase.fill",
         sortIndex: Int = 0, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.modifiedAt = .now
    }
}

extension WorkProfile {
    var displayName: String { name.isBlank ? "Untitled profile" : name.trimmed }
    var sessionCount: Int { (sessions ?? []).filter { !$0.isDeleted }.count }
    func touch() { modifiedAt = .now }
}
