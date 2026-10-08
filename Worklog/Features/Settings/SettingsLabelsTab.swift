import SwiftData
import SwiftUI

/// Labels & Tags: manage the label list (create, rename, color, symbol, reorder, archive, merge, delete with
/// reassignment) and tags (create, rename, color, parent label, archive, merge, delete).
@MainActor
struct SettingsLabelsTab: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case labels, tags
        var id: String { rawValue }
        var title: String { self == .labels ? "Labels" : "Tags" }
    }

    @Environment(\.theme) private var theme
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
            .padding(.vertical, theme.spacingM)
            .accessibilityLabel("Labels or tags")

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
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]
    @State private var selectedID: PersistentIdentifier?

    /// The query can briefly include labels deleted or merged a moment ago; never read those.
    private var liveLabels: [WorkLabel] { ModelLiveness.live(labels) }
    private var activeLabels: [WorkLabel] { liveLabels.filter { !$0.isArchived } }
    private var archivedLabels: [WorkLabel] { liveLabels.filter { $0.isArchived } }
    private var selectedLabel: WorkLabel? {
        guard let selectedID else { return nil }
        return liveLabels.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        if labels.isEmpty {
            VStack(spacing: theme.spacingM) {
                EmptyStateView(title: "No labels", systemImage: "tag",
                               actionTitle: "Restore defaults", action: restoreDefaults)
                Button("New Label", action: addLabel)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.bottom, theme.spacingXL)
            }
        } else {
            HStack(spacing: 0) {
                labelList
                    .frame(width: 230)
                Divider()
                Group {
                    if let label = selectedLabel {
                        SettingsLabelEditor(label: label, allLabels: liveLabels, onDeleted: { selectedID = nil },
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
        HStack(spacing: theme.spacingS) {
            Image(systemName: label.symbolName)
                .foregroundStyle(label.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(label.isArchived ? theme.textSecondary : theme.textPrimary)
            if settings.defaultLabelID == label.uuid {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(theme.textTertiary)
                    .help("Default label")
                    .accessibilityLabel("Default")
            }
            Spacer(minLength: theme.spacingXS)
            Text("\(label.usageCount)")
                .font(theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)
                .help("Times used")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(label.usageCount) uses\(label.isArchived ? ", archived" : "")")
    }

    // MARK: Actions

    private func moveLabels(from source: IndexSet, to destination: Int) {
        var ordered = activeLabels
        ordered.move(fromOffsets: source, toOffset: destination)
        TaxonomyOps.reorderLabels(ordered + archivedLabels)
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
        let label = TaxonomyOps.createLabel(name: name, colorHex: color, symbolName: "circle.fill", in: context)
        selectedID = label.persistentModelID
    }

    private func restoreDefaults() {
        UserDefaults.standard.set(false, forKey: SeedData.didSeedDefaultsKey)
        SeedData.seedIfNeeded(in: context)
        selectedID = nil
    }
}

// MARK: - Label editor

@MainActor
private struct SettingsLabelEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Bindable var label: WorkLabel
    let allLabels: [WorkLabel]
    let onDeleted: () -> Void
    let onMerged: (WorkLabel) -> Void

    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var showsDeleteSheet = false
    @State private var mergeTarget: WorkLabel?

    private var otherLabels: [WorkLabel] {
        allLabels.filter { $0.persistentModelID != label.persistentModelID && ModelLiveness.isLive($0) }
    }

    private var isDefault: Binding<Bool> {
        Binding(
            get: { settings.defaultLabelID == label.uuid },
            set: { newValue in
                if newValue {
                    settings.defaultLabelID = label.uuid
                } else if settings.defaultLabelID == label.uuid {
                    settings.defaultLabelID = nil
                }
            }
        )
    }

    var body: some View {
        if label.isDeleted || label.modelContext == nil {
            // Deleted or merged a moment ago; the pane switches selection on the next update.
            Color.clear
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $draftName)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                LabeledContent("Preview") {
                    LabelBadge(label: label)
                }
                Toggle("Default label", isOn: isDefault)
                    .disabled(label.isArchived)
            }

            Section("Color") {
                LabelColorPicker(hex: $label.colorHex)
            }

            Section("Symbol") {
                ScrollView {
                    SymbolPicker(symbolName: $label.symbolName)
                        .padding(theme.spacingXS)
                }
                .frame(height: 150)
            }

            Section("Usage") {
                SettingsFootnote(usageDescription)
            }

            Section {
                HStack(spacing: theme.spacingS) {
                    Button(label.isArchived ? "Unarchive" : "Archive", action: toggleArchive)
                        .buttonStyle(QuietButtonStyle())
                    Menu("Merge Into") {
                        ForEach(otherLabels) { other in
                            Button(other.isArchived ? "\(other.name) (archived)" : other.name) {
                                mergeTarget = other
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(otherLabels.isEmpty)
                    .help("Merge label")
                    Spacer()
                    Button("Delete…") { showsDeleteSheet = true }
                        .buttonStyle(DestructiveButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = label.name }
        .onChange(of: nameFocused) {
            if !nameFocused { commitName() }
        }
        .onDisappear {
            commitName()
            // Flush a color change still waiting in the debounce below.
            if !label.isDeleted, label.modelContext != nil, context.hasChanges { save() }
        }
        .task(id: label.colorHex) {
            // The color wheel reports every drag tick: save once the color settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
        .onChange(of: label.symbolName) { save() }
        .sheet(isPresented: $showsDeleteSheet) {
            SettingsDeleteLabelSheet(label: label, candidates: otherLabels) {
                showsDeleteSheet = false
                onDeleted()
            }
        }
        .confirmationDialog(
            mergeTarget.map { "Merge “\(label.name)” into “\($0.name)”?" } ?? "Merge labels?",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                guard let target = mergeTarget else { return }
                mergeTarget = nil
                TaxonomyOps.mergeLabel(label, into: target, settings: settings, in: context)
                onMerged(target)
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("Moves its sessions to “\(mergeTarget?.name ?? "")” and deletes it.")
        }
    }

    private var usageDescription: String {
        let sessions = label.sessions?.count ?? 0
        let segments = label.segments?.count ?? 0
        let tags = label.tags?.count ?? 0
        var parts = [
            "\(sessions) \(sessions == 1 ? "session" : "sessions")",
            "\(segments) \(segments == 1 ? "segment" : "segments")",
        ]
        if tags > 0 {
            parts.append("\(tags) \(tags == 1 ? "tag" : "tags")")
        }
        return parts.joined(separator: " · ")
    }

    private func commitName() {
        guard !label.isDeleted, label.modelContext != nil else { return }
        let trimmed = draftName.trimmed
        if trimmed.isEmpty {
            draftName = label.name
        } else if trimmed != label.name {
            label.name = trimmed
            save()
        }
    }

    private func toggleArchive() {
        label.isArchived.toggle()
        if label.isArchived && settings.defaultLabelID == label.uuid {
            settings.defaultLabelID = nil
        }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving label failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Delete label sheet

/// "Delete “Meetings”? 42 sessions use it. Move them to: ▾ [Unlabeled]" — reassign target, or archive instead.
@MainActor
private struct SettingsDeleteLabelSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let label: WorkLabel
    let candidates: [WorkLabel]
    let onDeleted: () -> Void

    @State private var targetID: PersistentIdentifier?

    private var sortedCandidates: [WorkLabel] {
        candidates.filter { !$0.isArchived } + candidates.filter { $0.isArchived }
    }

    var body: some View {
        if label.isDeleted || label.modelContext == nil {
            Color.clear.frame(width: 460, height: 120)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let sessions = label.sessions?.count ?? 0
        let segments = label.segments?.count ?? 0
        VStack(alignment: .leading, spacing: theme.spacingL) {
            Text("Delete “\(label.name)”?")
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
            Text(sessions + segments == 0
                 ? "No sessions use this label."
                 : "\(sessions) \(sessions == 1 ? "session" : "sessions") and \(segments) \(segments == 1 ? "segment" : "segments") use it.")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Move them to", selection: $targetID) {
                Text("Unlabeled").tag(PersistentIdentifier?.none)
                Divider()
                ForEach(sortedCandidates) { candidate in
                    Text(candidate.isArchived ? "\(candidate.name) (archived)" : candidate.name)
                        .tag(Optional(candidate.persistentModelID))
                }
            }

            if (label.tags?.count ?? 0) > 0 {
                SettingsFootnote("Its tags move along, or become global.")
            }
            SettingsFootnote("Archiving only hides it from pickers.")

            HStack(spacing: theme.spacingS) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !label.isArchived {
                    Button("Archive Instead") {
                        label.isArchived = true
                        if settings.defaultLabelID == label.uuid { settings.defaultLabelID = nil }
                        try? context.save()
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Delete Label", role: .destructive) {
                    let target = sortedCandidates.first { $0.persistentModelID == targetID }
                    TaxonomyOps.deleteLabel(label, reassignTo: target, settings: settings, in: context)
                    onDeleted()
                }
                .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(theme.spacingXL)
        .frame(width: 460)
    }
}
