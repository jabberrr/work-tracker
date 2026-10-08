import SwiftData
import SwiftUI

/// Labels & Tags: manage the label list (create, rename, color, symbol, reorder, archive, merge, delete with
/// reassignment) and tags (create, rename, color, parent label, archive, merge, delete).
///
/// Both lists show what the current profile offers: global items (trailing globe) plus its own. New items are
/// local to the current profile; "Available in" switches an item between all profiles and this profile only.
@MainActor
struct SettingsLabelsTab: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case labels, tags
        var id: String { rawValue }
        var title: String { self == .labels ? "Labels" : "Tags" }
    }

    @Environment(\.theme) private var theme
    @Environment(ProfileStore.self) private var profileStore
    @State private var pane: Pane = .labels

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Labels or tags")
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                // Whose labels these are, when there is more than one profile.
                if profileStore.hasMultipleProfiles {
                    ProfileBadge(profile: profileStore.activeProfile, size: .small)
                        .padding(.leading, theme.spacingL)
                }
            }
            .padding(.vertical, theme.spacingM)

            Divider()

            switch pane {
            case .labels: SettingsLabelsPane()
            case .tags: SettingsTagsPane()
            }
        }
    }
}

// MARK: - Labels pane

@MainActor
struct SettingsLabelsPane: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.theme) private var theme
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]
    @State private var selectedID: PersistentIdentifier?

    /// Every live label (all profiles). The query can briefly include labels deleted or merged a moment ago;
    /// never read those.
    private var allLiveLabels: [WorkLabel] { ModelLiveness.live(labels) }
    /// Labels the current profile offers (global + its own), in sortIndex order.
    private var liveLabels: [WorkLabel] {
        let scope = profileStore.activeScope
        return allLiveLabels.filter { scope.offers($0) }
    }
    private var activeLabels: [WorkLabel] { liveLabels.filter { !$0.isArchived } }
    /// Scope marks and controls appear once there is more than one profile (archived ones count).
    private var showsScope: Bool { profileStore.showsProfileScope }
    private var archivedLabels: [WorkLabel] { liveLabels.filter { $0.isArchived } }
    private var selectedLabel: WorkLabel? {
        guard let selectedID else { return nil }
        return liveLabels.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        if allLiveLabels.isEmpty {
            VStack(spacing: theme.spacingM) {
                EmptyStateView(title: "No labels", systemImage: "tag",
                               actionTitle: "Restore defaults", action: restoreDefaults)
                Button("New Label", action: addLabel)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.bottom, theme.spacingXL)
            }
        } else if liveLabels.isEmpty {
            // Labels exist, but all belong to other profiles (a new profile).
            EmptyStateView(title: "No labels", systemImage: "tag",
                           actionTitle: "New Label", action: addLabel)
        } else {
            HStack(spacing: 0) {
                labelList
                    .frame(width: 230)
                Divider()
                Group {
                    if let label = selectedLabel {
                        SettingsLabelEditor(label: label, allLabels: allLiveLabels, offeredLabels: liveLabels,
                                            onDeleted: { selectedID = nil },
                                            onMerged: { target in selectedID = target.persistentModelID })
                            .id(label.persistentModelID)
                    } else {
                        EmptyStateView(title: "Select a label", systemImage: "tag")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                if selectedID == nil { selectedID = activeLabels.first?.persistentModelID }
            }
            .onChange(of: profileStore.activeProfileID) {
                selectedID = activeLabels.first?.persistentModelID
            }
        }
    }

    private var labelList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Labels") {
                    ForEach(activeLabels) { label in
                        row(label)
                            .tag(label.persistentModelID)
                    }
                    .onMove(perform: moveLabels)
                }
                if !archivedLabels.isEmpty {
                    Section("Archived") {
                        ForEach(archivedLabels) { label in
                            row(label)
                                .tag(label.persistentModelID)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: theme.spacingS) {
                Button(action: addLabel) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("New label")
                .accessibilityLabel("New label")
                Spacer()
                Text("Drag to reorder")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, theme.spacingXS)
        }
        .themedBackground(.sidebar)
    }

    private func row(_ label: WorkLabel) -> some View {
        // Uses in the current profile only (a global label's other profiles aren't counted).
        let uses: Int = SettingsScopedUsage.of(label, in: profileStore.activeScope).total
        let isGlobalShown: Bool = showsScope && label.isAvailableEverywhere
        let a11yValue: String = "\(uses) uses" + (label.isArchived ? ", archived" : "")
            + (isGlobalShown ? ", all profiles" : "")
        return HStack(spacing: theme.spacingS) {
            Image(systemName: label.symbolName)
                .foregroundStyle(label.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(label.isArchived ? theme.textSecondary : theme.textPrimary)
            if let profile = ModelLiveness.live(profileStore.activeProfile), profile.defaultLabelUUID == label.uuid {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(theme.textTertiary)
                    .help("Default label")
                    .accessibilityLabel("Default")
            }
            Spacer(minLength: theme.spacingXS)
            if isGlobalShown {
                SettingsGlobalMark()
            }
            Text("\(uses)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Times used")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11yValue)
    }

    // MARK: Actions

    /// Reorders the visible labels within the slots they already hold in the full list, so labels of other
    /// profiles keep their place, then renumbers everything.
    private func moveLabels(from source: IndexSet, to destination: Int) {
        var ordered = activeLabels
        ordered.move(fromOffsets: source, toOffset: destination)
        let visible = ordered + archivedLabels
        let visibleIDs = Set(visible.map(\.persistentModelID))
        var next = visible.makeIterator()
        let merged = allLiveLabels.map { label in
            visibleIDs.contains(label.persistentModelID) ? (next.next() ?? label) : label
        }
        TaxonomyOps.reorderLabels(merged)
    }

    private func addLabel() {
        let labels = liveLabels
        let usedColors = Set(labels.map { LabelPalette.normalized($0.colorHex) })
        let palette = LabelPalette.hexColors
        let color = palette.first { !usedColors.contains(LabelPalette.normalized($0)) }
            ?? (palette.isEmpty ? "#5B8DEF" : palette[labels.count % palette.count])
        let existingNames = Set(labels.map { $0.name.lowercased() })
        var name = "New label"
        var counter = 2
        while existingNames.contains(name.lowercased()) {
            name = "New label \(counter)"
            counter += 1
        }
        let label = TaxonomyOps.createLabel(name: name, colorHex: color, symbolName: "circle.fill",
                                            profile: ModelLiveness.live(profileStore.activeProfile), in: context)
        selectedID = label.persistentModelID
    }

    private func restoreDefaults() {
        UserDefaults.standard.set(false, forKey: SeedData.didSeedDefaultsKey)
        SeedData.seedIfNeeded(in: context)
        selectedID = nil
    }
}
