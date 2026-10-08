import SwiftData
import SwiftUI

// Pieces shared by the label and tag panes of Settings ▸ Labels & Tags.

// MARK: - Scope (shared with the tags pane)

/// "Available in **All profiles**" / "Available in **Work only**".
enum SettingsTaxonomyScope: Hashable {
    case allProfiles
    case thisProfile
}

/// The "Available in" value sentence of the label and tag editors.
struct SettingsScopePicker: View {
    @Binding var selection: SettingsTaxonomyScope
    let profileName: String

    var body: some View {
        let name = profileName
        ValuePicker("Available in", selection: $selection, options: [.allProfiles, .thisProfile],
                    title: { $0 == .allProfiles ? "All profiles" : "\(name) only" })
    }
}

/// Uses of a label or tag counted in one profile scope: sessions, segments and learning points whose session the
/// scope contains. `ProfileScope.allProfiles` counts every live use.
struct SettingsScopedUsage {
    var sessions = 0
    var segments = 0
    var points = 0
    var total: Int { sessions + segments + points }

    @MainActor static func of(_ label: WorkLabel, in scope: ProfileScope) -> SettingsScopedUsage {
        var usage = SettingsScopedUsage()
        guard ModelLiveness.isLive(label) else { return usage }
        usage.sessions = (label.sessions ?? []).filter { scope.contains($0) }.count
        usage.segments = (label.segments ?? []).filter { contains($0, in: scope) }.count
        return usage
    }

    @MainActor static func of(_ tag: WorkTag, in scope: ProfileScope) -> SettingsScopedUsage {
        var usage = SettingsScopedUsage()
        guard ModelLiveness.isLive(tag) else { return usage }
        usage.sessions = (tag.sessions ?? []).filter { scope.contains($0) }.count
        usage.segments = (tag.segments ?? []).filter { contains($0, in: scope) }.count
        usage.points = (tag.learningPoints ?? []).filter { scope.contains($0) }.count
        return usage
    }

    @MainActor private static func contains(_ segment: Segment, in scope: ProfileScope) -> Bool {
        guard ModelLiveness.isLive(segment) else { return false }
        guard let session = ModelLiveness.live(segment.session) else { return scope.isAllProfiles }
        return scope.contains(session)
    }
}

/// Trailing globe on a global label or tag row.
struct SettingsGlobalMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "globe")
            .imageScale(.small)
            .foregroundStyle(theme.textTertiary)
            .help("All profiles")
            .accessibilityHidden(true)
    }
}

extension WorkLabel {
    /// Offered in every profile: no profile, or its profile was deleted. False for a deleted label.
    @MainActor var isAvailableEverywhere: Bool {
        ModelLiveness.isLive(self) && ModelLiveness.live(profile) == nil
    }
}

extension WorkTag {
    /// Offered in every profile: no profile, or its profile was deleted. False for a deleted tag.
    @MainActor var isAvailableEverywhere: Bool {
        ModelLiveness.isLive(self) && ModelLiveness.live(profile) == nil
    }
}
