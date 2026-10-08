import AppKit
import SwiftUI
import SwiftData
import Combine

/// History: a searchable, sortable, filterable list of ended sessions (left) and the selected session's
/// `SessionDetailView` (right), side by side in a plain `HStack`.
///
/// Layout: the list column has an explicit width (`history.listWidth`, 280…460, default 340) that only
/// changes by dragging the divider, and the detail fills the remaining space with `minWidth: 0` and
/// clipping, so neither column's content can change the other's width or push a minimum size up to the
/// window. (An `HSplitView` here re-measured its panes on every selection and leaked their minimums.)
///
/// Performance: the `@Query` fetch is the only work tied to the store; filtering (label, tag, search),
/// sorting and grouping run in `recompute()` when an input changes (search debounced 150 ms, store saves
/// debounced 300 ms) and the result is kept in `@State`. `body` only lays out the precomputed sections and
/// `List` builds rows lazily.
@MainActor
struct HistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(WindowRouter.self) private var router
    @Environment(SessionEngine.self) private var engine
    @Environment(ShortcutStore.self) private var shortcuts

    @Query(filter: #Predicate<WorkSession> { $0.endedAt != nil },
           sort: \WorkSession.startedAt, order: .reverse)
    private var sessions: [WorkSession]
    @Query(sort: \WorkLabel.sortIndex) private var labels: [WorkLabel]
    @Query(sort: \WorkTag.name) private var tags: [WorkTag]

    @AppStorage("history.sort") private var sort: HistorySort = .dateNewest
    @AppStorage("history.listWidth") private var storedListWidth: Double = HistoryColumnLayout.defaultListWidth
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var labelFilter: PersistentIdentifier?
    @State private var tagFilter: PersistentIdentifier?
    @State private var sections: [HistorySection] = []
    @State private var resultCount = 0
    @State private var storeChangeCount = 0
    @State private var pendingDelete: WorkSession?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    init() {}

    var body: some View {
        Group {
            if sessions.isEmpty && !engine.isActive {
                EmptyStateView(title: "No sessions yet",
                               systemImage: "clock",
                               message: "Finished sessions appear here.",
                               actionTitle: "Start session") {
                    router.show(.today)
                }
            } else {
                columns
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .themedBackground()
        .background { findShortcut }
        // Search: debounce typing, apply clearing immediately. Also runs the first computation on appear.
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            appliedQuery = query
            recompute()
        }
        // Store saves (edits in the detail pane, sync, import): coalesce, then refresh order/filters.
        .task(id: storeChangeCount) {
            guard storeChangeCount > 0 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            recompute()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            storeChangeCount &+= 1
        }
        .onChange(of: sessions) { _, _ in recompute() }
        .onChange(of: sort) { _, _ in recompute() }
        .onChange(of: labelFilter) { _, _ in recompute() }
        .onChange(of: tagFilter) { _, _ in recompute() }
        .confirmationDialog("Delete this session?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { session in
            Button("Delete Session", role: .destructive) { delete(session) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .alert("Couldn’t delete the session",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Columns

    /// List (explicit width) | 1 pt divider with a drag handle | detail (fills the rest, never drives size).
    private var columns: some View {
        GeometryReader { proxy in
            let total = Double(proxy.size.width)
            let width = HistoryColumnLayout.clampedListWidth(storedListWidth, total: total)
            HStack(spacing: 0) {
                listColumn
                    .frame(width: CGFloat(width))
                    .frame(minHeight: 0, maxHeight: .infinity)
                HistoryColumnDivider(width: $storedListWidth, currentWidth: width, total: total)
                    .zIndex(1)
                detailColumn
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                HStack(spacing: theme.spacingXS) {
                    SearchField(text: $query, prompt: "Search sessions", isFocused: $searchFocused)
                        .help("Search")
                    filterMenu
                    sortMenu
                }
                labelChips
                if let tagID = tagFilter, let tag = ModelLiveness.live(tags).first(where: { $0.persistentModelID == tagID }) {
                    HStack(spacing: theme.spacingXS) {
                        Text("Tag")
                            .font(theme.captionFont)
                            .foregroundStyle(theme.textTertiary)
                        TagChip(tag: tag, isSelected: true, onRemove: { tagFilter = nil })
                    }
                }
            }
            .padding(.horizontal, theme.spacingM)
            .padding(.vertical, theme.spacingS)

            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)

            if resultCount == 0 && hasFilters && !sessions.isEmpty {
                VStack(spacing: 0) {
                    if engine.isActive {
                        HistoryLiveRow { router.selection = .today }
                            .padding(.horizontal, theme.spacingL)
                            .padding(.top, theme.spacingS)
                    }
                    noResults
                }
            } else {
                sessionList
            }
        }
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            sessionListContent
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: router.selectedSessionID) { _, _ in scrollToSelection(proxy) }
                .onChange(of: resultCount) { _, _ in scrollToSelection(proxy) }
        }
    }

    /// Reveals the selected row (e.g. after `router.showSession` from Today, the menu bar or Learning).
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = router.selectedSessionID,
              sections.contains(where: { section in section.sessions.contains { $0.persistentModelID == id } })
        else { return }
        proxy.scrollTo(id)
    }

    private var sessionListContent: some View {
        List(selection: Binding(get: { router.selectedSessionID },
                                set: { router.selectedSessionID = $0 })) {
            if engine.isActive {
                HistoryLiveRow { router.selection = .today }
            }
            if sessions.isEmpty {
                Text("Finished sessions appear here.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.sessions, id: \.persistentModelID) { session in
                        HistoryRowView(session: session, query: appliedQuery, showsDate: !sort.groupsByDay)
                            .tag(session.persistentModelID)
                            .contextMenu {
                                Button("Delete Session…", role: .destructive) {
                                    pendingDelete = session
                                }
                            }
                    }
                } header: {
                    HistorySectionHeader(section: section)
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            if let id = router.selectedSessionID, let session = sessionForID(id) {
                pendingDelete = session
            }
        }
        .accessibilityLabel("Sessions")
    }

    private var noResults: some View {
        let trimmed = query.trimmed
        let message = trimmed.isEmpty
            ? "No sessions match these filters."
            : "Nothing matches “\(trimmed)”."
        let hasChipFilters = labelFilter != nil || tagFilter != nil
        let clear: (() -> Void)? = hasChipFilters ? { clearFilters() } : nil
        return EmptyStateView(title: "No matches",
                              systemImage: "magnifyingglass",
                              message: message,
                              actionTitle: hasChipFilters ? "Clear filters" : nil,
                              action: clear)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(HistorySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .accessibilityLabel("Sort sessions")
        .accessibilityValue(sort.title)
    }

    private var filterMenu: some View {
        let activeTags = ModelLiveness.live(tags).filter { !$0.isArchived || $0.persistentModelID == tagFilter }
        return Menu {
            Picker("Filter by tag", selection: $tagFilter) {
                Text("Any tag").tag(PersistentIdentifier?.none)
                ForEach(activeTags) { tag in
                    Text(tag.name).tag(Optional(tag.persistentModelID))
                }
            }
            .pickerStyle(.inline)
            if hasFilters {
                Divider()
                Button("Clear Filters") { clearFilters() }
            }
        } label: {
            Image(systemName: tagFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by tag")
        .accessibilityLabel("Filter by tag")
        .accessibilityValue(tagFilter == nil ? "Any tag" : "Filtered")
    }

    private var labelChips: some View {
        let visibleLabels = ModelLiveness.live(labels).filter { !$0.isArchived || $0.persistentModelID == labelFilter }
        // Wraps onto more lines rather than scrolling sideways, so every label stays reachable with a mouse.
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            FilterChip("All", colorHex: nil, isSelected: labelFilter == nil) {
                labelFilter = nil
            }
            .help("All")
            ForEach(visibleLabels) { label in
                let selected = labelFilter == label.persistentModelID
                let title = label.name.isBlank ? "Untitled label" : label.name
                FilterChip(title, colorHex: label.colorHex, isSelected: selected) {
                    labelFilter = selected ? nil : label.persistentModelID
                }
                .help(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by label")
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let id = router.selectedSessionID, let session = sessionForID(id) {
            SessionDetailView(session: session)
                .id(id)
        } else if let id = router.selectedSessionID, let active = engine.activeSession,
                  active.persistentModelID == id {
            EmptyStateView(title: "Session in progress",
                           systemImage: "timer",
                           actionTitle: "Go to Today") {
                router.selection = .today
            }
        } else {
            EmptyStateView(title: "Select a session",
                           systemImage: "sidebar.left")
        }
    }

    /// Hidden "Find in History" target (customizable, default ⌘F) that focuses the search field.
    private var findShortcut: some View {
        Button("Find") { searchFocused = true }
            .keyboardShortcut(shortcuts.shortcut(for: .findInHistory))
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: - Data

    private var hasFilters: Bool {
        !appliedQuery.isBlank || labelFilter != nil || tagFilter != nil
    }

    private func sessionForID(_ id: PersistentIdentifier) -> WorkSession? {
        sessions.first { $0.persistentModelID == id && !$0.isDeleted }
    }

    private func clearFilters() {
        labelFilter = nil
        tagFilter = nil
        query = ""
    }

    private func recompute() {
        var list = sessions.filter { !$0.isDeleted }
        if let labelID = labelFilter {
            list = list.filter { session in
                session.label?.persistentModelID == labelID
                    || (session.segments ?? []).contains { $0.label?.persistentModelID == labelID }
            }
        }
        if let tagID = tagFilter {
            list = list.filter { session in
                session.tagList.contains { $0.persistentModelID == tagID }
                    || (session.segments ?? []).contains { segment in
                        segment.tagList.contains { $0.persistentModelID == tagID }
                    }
            }
        }
        list = SearchService.filter(list, query: appliedQuery)
        resultCount = list.count
        sections = HistoryGrouping.sections(for: list, sort: sort)
    }

    private func delete(_ session: WorkSession) {
        pendingDelete = nil
        guard !session.isDeleted, let context = session.modelContext else { return }
        let id = session.persistentModelID

        // Move the selection to a neighbour first so no view keeps showing the deleted model.
        if router.selectedSessionID == id {
            let flat = sections.flatMap(\.sessions)
            var next: PersistentIdentifier?
            if let index = flat.firstIndex(where: { $0.persistentModelID == id }) {
                if index + 1 < flat.count {
                    next = flat[index + 1].persistentModelID
                } else if index > 0 {
                    next = flat[index - 1].persistentModelID
                }
            }
            router.selectedSessionID = next
        }
        sections = sections.compactMap { section in
            var copy = section
            copy.sessions.removeAll { $0.persistentModelID == id }
            return copy.sessions.isEmpty ? nil : copy
        }
        resultCount = max(0, resultCount - 1)

        // Delete a moment later, after SwiftUI has re-rendered without the detail pane and the row that
        // showed this session (deleting while they are still mounted can touch a detached model).
        // The engine refreshes the takeaway itself when the store saves.
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            guard !session.isDeleted, session.modelContext != nil else { return }
            do {
                try SessionEditor.deleteSession(session, in: context)
            } catch {
                errorMessage = error.localizedDescription
                recompute()
            }
        }
    }
}

// MARK: - Column layout

/// List-column width rules (also used by the divider while dragging).
fileprivate enum HistoryColumnLayout {
    static let defaultListWidth: Double = 340
    static let minListWidth: Double = 280
    static let maxListWidth: Double = 460
    /// Space always left for the detail column (when the window allows it).
    static let minDetailWidth: Double = 420

    /// `stored` clamped to 280 … min(460, total − 420); never below 280.
    static func clampedListWidth(_ stored: Double, total: Double) -> Double {
        let upper = max(minListWidth, min(maxListWidth, total - minDetailWidth))
        let value = stored.isFinite ? stored : defaultListWidth
        return min(max(value, minListWidth), upper)
    }
}

/// 1 pt separator between the list and the detail with a 7 pt invisible drag handle. Dragging resizes the
/// list live (no animation), double-click resets it to 340. Shows the resize cursor while hovered or dragged.
fileprivate struct HistoryColumnDivider: View {
    @Environment(\.theme) private var theme
    @Binding var width: Double
    /// The list width currently laid out (already clamped).
    let currentWidth: Double
    /// Width of the whole History page, for clamping.
    let total: Double

    @State private var dragStartWidth: Double?
    @State private var isHovering = false
    @State private var cursorPushed = false

    init(width: Binding<Double>, currentWidth: Double, total: Double) {
        self._width = width
        self.currentWidth = currentWidth
        self.total = total
    }

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        isHovering = inside
                        updateCursor()
                    }
                    // AppKit cursor rects of neighbouring views (text, list) can reset the pushed cursor;
                    // re-assert it while the pointer moves over the handle.
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.resizeLeftRight.set() }
                    }
                    .onTapGesture(count: 2) {
                        setWidth(HistoryColumnLayout.defaultListWidth)
                    }
                    .gesture(drag)
            }
            .onDisappear {
                isHovering = false
                dragStartWidth = nil
                updateCursor()
            }
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        // Global space: the handle moves with the drag, so local translations would feed back.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? currentWidth
                if dragStartWidth == nil {
                    dragStartWidth = start
                    updateCursor()
                }
                NSCursor.resizeLeftRight.set()
                let proposed = start + Double(value.translation.width)
                setWidth(HistoryColumnLayout.clampedListWidth(proposed, total: total))
            }
            .onEnded { _ in
                dragStartWidth = nil
                updateCursor()
            }
    }

    private func setWidth(_ value: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            width = value
        }
    }

    /// Keeps `NSCursor` push/pop balanced: one push while hovered or dragging, one pop when neither.
    private func updateCursor() {
        let wantsCursor = isHovering || dragStartWidth != nil
        if wantsCursor && !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !wantsCursor && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

#Preview("History") {
    HistoryView()
        .withAppServices(.preview)
        .frame(width: 1000, height: 700)
}
