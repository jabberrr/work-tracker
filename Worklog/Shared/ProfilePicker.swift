import SwiftUI
import SwiftData

/// Native pop-up `Picker` (`.menu`) over the non-archived profiles, plus the current selection when it is
/// archived ("Name (archived)"), tagged by UUID, with each profile's symbol in its color (`LabelMenuIcon`).
/// For Session detail's "Profile" row. Shows its `title` on the left; add `.labelsHidden()` where the context
/// says it.
///
/// A selection that doesn't resolve (nil, or a deleted profile) shows "No profile". Picking writes the profile's
/// UUID; nil is never written (every session belongs to a profile). Reads `ProfileStore` from the environment.
@MainActor
struct ProfilePicker: View {
    @Environment(ProfileStore.self) private var profiles
    @Binding private var selection: UUID?
    private let title: String

    init(selection: Binding<UUID?>, title: String = "Profile") {
        self._selection = selection
        self.title = title
    }

    var body: some View {
        let active = ModelLiveness.live(profiles.profiles)
        let archived = ModelLiveness.live(profiles.archivedProfiles)
        let current = selection.flatMap { id in (active + archived).first { $0.uuid == id } }
        let items: [WorkProfile] = {
            guard let current, !active.contains(where: { $0.uuid == current.uuid }) else { return active }
            return active + [current]
        }()
        Picker(selection: Binding<UUID?>(
            get: { current?.uuid },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )) {
            if current == nil {
                Text("No profile").tag(UUID?.none)
                if !items.isEmpty {
                    Divider()
                }
            }
            ForEach(items, id: \.uuid) { profile in
                Label {
                    Text(verbatim: profile.isArchived ? "\(profile.displayName) (archived)" : profile.displayName)
                } icon: {
                    Image(nsImage: LabelMenuIcon.image(symbol: profile.symbolName, hex: profile.colorHex))
                        .renderingMode(.original)
                }
                .tag(Optional(profile.uuid))
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
        .accessibilityValue(current?.displayName ?? "No profile")
    }
}

/// Settings value sentence over profiles: "Quick start in **Current profile ⌄**" (a `ValuePicker`: value bold in
/// the accent color, popover list). Options: nil (reads `nilTitle`), then the non-archived profiles in order.
/// A selection that no longer resolves (archived or deleted) reads as `nilTitle` and nil is written back
/// (on appear and whenever the profile list changes, once profiles are loaded). Reads `ProfileStore` from the
/// environment; the popover only holds UUIDs and names.
@MainActor
struct ProfileValuePicker: View {
    @Environment(ProfileStore.self) private var profiles
    @Binding private var selection: UUID?
    private let prefix: String
    private let nilTitle: String

    init(_ prefix: String, selection: Binding<UUID?>, nilTitle: String) {
        self.prefix = prefix
        self._selection = selection
        self.nilTitle = nilTitle
    }

    private var liveProfiles: [WorkProfile] { ModelLiveness.live(profiles.profiles) }

    var body: some View {
        let items = liveProfiles
        let names = Dictionary(items.map { ($0.uuid, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let resolved: UUID? = selection.flatMap { names[$0] == nil ? nil : $0 }
        let ids: [UUID?] = [nil] + items.map { Optional($0.uuid) }
        let fallback = nilTitle
        ValuePicker(prefix,
                    selection: Binding<UUID?>(get: { resolved }, set: { selection = $0 }),
                    options: ids,
                    title: { id in id.flatMap { names[$0] } ?? fallback })
            .onAppear(perform: dropUnresolvedSelection)
            .onChange(of: items.map(\.uuid)) { _, _ in
                dropUnresolvedSelection()
            }
    }

    /// Writes nil back when the stored profile is gone or archived. Skipped while no profile is loaded, so a
    /// store that is still empty (first launch, before sync) never clears the setting.
    private func dropUnresolvedSelection() {
        guard let id = selection else { return }
        let ids = liveProfiles.map(\.uuid)
        guard !ids.isEmpty, !ids.contains(id) else { return }
        selection = nil
    }
}
