import AppKit
import SwiftData
import SwiftUI

/// Read-only row for one logged Trello entry: time (shortTime), the kind's symbol, the one-line summary and a caption
/// (comment excerpt · board name).
///
///     10:42  →  Moved “Fix login” from Doing to Done          ›
///               Website
///
/// `isCompact` (live list, review sheet): callout font, one line each. `isExpanded` (non-nil inside a
/// `TrelloActivityDisclosure`) adds a trailing chevron. Actions (open, copy, remove) are added by the host, through
/// `TrelloActivityActions` / `TrelloActivityMenuItems`. A deleted entry renders nothing.
@MainActor
struct TrelloActivityRow: View {
    @Environment(\.theme) private var theme
    private let activity: TrelloActivity
    private let isCompact: Bool
    private let isExpanded: Bool?

    /// Longest comment / description excerpt shown in the caption (description edits store the full text).
    private static let excerptLimit = 200

    init(activity: TrelloActivity, isCompact: Bool = false, isExpanded: Bool? = nil) {
        self.activity = activity
        self.isCompact = isCompact
        self.isExpanded = isExpanded
    }

    var body: some View {
        if ModelLiveness.isLive(activity) {
            content
        }
    }

    private var content: some View {
        let time = activity.occurredAt.shortTime
        let summary = activity.summary
        let caption = captionText
        return HStack(alignment: .firstTextBaseline, spacing: theme.spacingM) {
            Text(time)
                .font(theme.captionFont.monospacedDigit())
                .foregroundStyle(theme.textTertiary)
                .frame(minWidth: 54, alignment: .leading)
            Image(systemName: activity.systemImage)
                .font(theme.captionFont)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(isCompact ? theme.calloutFont : theme.bodyFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(isCompact ? 1 : 3)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let caption {
                    Text(caption)
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(isCompact ? 1 : 2)
                        .truncationMode(.tail)
                }
            }
            if let isExpanded {
                TrelloDisclosureChevron(isExpanded: isExpanded)
            }
        }
        .padding(.vertical, isCompact ? 2 : theme.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(summary: summary, time: time, caption: caption))
    }

    /// "“Looks good to me”" (comments and description edits, one line) · board name, or nil.
    private var captionText: String? {
        var parts: [String] = []
        if activity.kind == .commented || activity.kind == .editedDescription, !activity.detail.isBlank {
            parts.append("\u{201C}\(Self.excerpt(activity.detail))\u{201D}")
        }
        if !activity.boardName.isBlank {
            parts.append(activity.boardName.trimmed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The text on one line (line breaks become spaces), at most `excerptLimit` characters plus "…".
    private static func excerpt(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let flat = lines.joined(separator: " ")
        guard flat.count > excerptLimit else { return flat }
        return String(flat.prefix(excerptLimit)) + "…"
    }

    private func accessibilityText(summary: String, time: String, caption: String?) -> String {
        if let caption {
            return "\(summary), \(caption), at \(time)"
        }
        return "\(summary), at \(time)"
    }
}

/// Trailing "›" that turns down while the entry's card is shown. Decorative (the row carries the state).
private struct TrelloDisclosureChevron: View {
    @Environment(\.theme) private var theme
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(theme.captionFont.weight(.semibold))
            .foregroundStyle(theme.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

// MARK: - Disclosure (row + card box)

/// A logged entry that shows its card when clicked: the whole row is a plain button that toggles `expandedID`
/// (owned by the list, so one card is open at a time per list), with `TrelloCardBox` directly under it. Context menu:
/// Open in Trello, Copy (+ Remove from Session when `onRemove` is set). `accessory` sits trailing the row (the
/// detail's ⋯ menu). A deleted entry renders nothing.
@MainActor
struct TrelloActivityDisclosure<Accessory: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var expandedID: UUID?
    private let activity: TrelloActivity
    private let isCompact: Bool
    private let onRemove: (() -> Void)?
    private let accessory: Accessory

    init(activity: TrelloActivity, isCompact: Bool = false, expandedID: Binding<UUID?>,
         onRemove: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self._expandedID = expandedID
        self.activity = activity
        self.isCompact = isCompact
        self.onRemove = onRemove
        self.accessory = accessory()
    }

    var body: some View {
        if ModelLiveness.isLive(activity) {
            content(isExpanded: expandedID == activity.uuid)
        }
    }

    private func content(isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            HStack(alignment: .top, spacing: theme.spacingS) {
                toggle(isExpanded: isExpanded)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                accessory
            }
            if isExpanded {
                TrelloCardBox(activity: activity)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, isExpanded ? theme.spacingS : 0)
    }

    private func toggle(isExpanded: Bool) -> some View {
        let action = isExpanded ? "Hide card" : "Show card"
        let value = isExpanded ? "Card shown" : ""
        return Button {
            toggleExpansion()
        } label: {
            TrelloActivityRow(activity: activity, isCompact: isCompact, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .help(isCompact ? activity.summary : action)
        .accessibilityHint(action)
        .accessibilityValue(value)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .contextMenu {
            TrelloActivityMenuItems(activity: activity, onRemove: onRemove)
        }
    }

    private func toggleExpansion() {
        guard ModelLiveness.isLive(activity) else { return }
        let id = activity.uuid
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            expandedID = expandedID == id ? nil : id
        }
    }
}

extension TrelloActivityDisclosure where Accessory == EmptyView {
    init(activity: TrelloActivity, isCompact: Bool = false, expandedID: Binding<UUID?>,
         onRemove: (() -> Void)? = nil) {
        self.init(activity: activity, isCompact: isCompact, expandedID: expandedID, onRemove: onRemove) {
            EmptyView()
        }
    }
}

/// Open in Trello, Copy, and (with `onRemove`) Divider + Remove from Session: the context menu and the detail's ⋯ menu.
@MainActor
struct TrelloActivityMenuItems: View {
    let activity: TrelloActivity
    let onRemove: (() -> Void)?

    var body: some View {
        Button("Open in Trello") { TrelloActivityActions.open(activity) }
            .disabled(!ModelLiveness.isLive(activity) || activity.cardURL == nil)
        Button("Copy") { TrelloActivityActions.copy(activity) }
        if let onRemove {
            Divider()
            Button("Remove from Session", role: .destructive, action: onRemove)
        }
    }
}

// MARK: - Card box

private struct TrelloCardLoadKey: Equatable {
    var shortLink: String
    var generation: Int
}

/// The entry's card as it is now in Trello (`TrelloService.cardDetails`), shown under an expanded row: name,
/// "Board › List", status chips, labels, description, checklists, last activity, Open in Trello and refresh. A
/// cached card shows at once. For a description edit, "This edit" (the text saved with the entry) comes first.
/// Deleted card / unavailable (not connected, offline, no link): one short line instead.
@MainActor
struct TrelloCardBox: View {
    @Environment(TrelloService.self) private var trello
    @Environment(\.theme) private var theme
    private let activity: TrelloActivity

    @State private var lookup: TrelloCardLookup?
    /// Why the last refresh failed while an older card stays on screen.
    @State private var refreshFailure: String?
    @State private var isLoading = false
    /// Bumped by the refresh button; > 0 loads with `forceRefresh`.
    @State private var generation = 0

    init(activity: TrelloActivity) {
        self.activity = activity
    }

    var body: some View {
        if ModelLiveness.isLive(activity) {
            box(shortLink: activity.cardShortLink.trimmed)
        }
    }

    private func box(shortLink: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        return VStack(alignment: .leading, spacing: theme.spacingS) {
            state(lookup)
        }
        .padding(theme.spacingM)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.insetSurface))
        .overlay(shape.strokeBorder(theme.separator, lineWidth: theme.borderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trello card")
        .onAppear {
            // Not observed: read once, so a cached card shows at once; `load` replaces it.
            if lookup == nil {
                lookup = cached(shortLink: shortLink)
            }
        }
        .task(id: TrelloCardLoadKey(shortLink: shortLink, generation: generation)) {
            await load(shortLink: shortLink, forceRefresh: generation > 0)
        }
    }

    @ViewBuilder
    private func state(_ shown: TrelloCardLookup?) -> some View {
        let edit = editText
        switch shown {
        case .some(.loaded(let details)):
            TrelloCardDetailsView(details: details, fallbackName: activity.cardName, editText: edit,
                                  footer: footer(lastActivity: details.lastActivity, url: openURL(details)))
        case .some(.deleted):
            TrelloCardMessage(systemImage: "trash", text: "This card was deleted in Trello.", isWarning: false)
            if let edit {
                TrelloCardTextBlock(title: "This edit", text: edit, isQuoted: true)
            }
        case .some(.unavailable(let reason)):
            TrelloCardMessage(systemImage: "exclamationmark.triangle", text: reason, isWarning: true)
            if let edit {
                TrelloCardTextBlock(title: "This edit", text: edit, isQuoted: true)
            }
            footer(lastActivity: nil, url: openURL(nil))
        case .none:
            TrelloCardLoadingLine()
            if let edit {
                TrelloCardTextBlock(title: "This edit", text: edit, isQuoted: true)
            }
        }
    }

    private func footer(lastActivity: Date?, url: URL?) -> TrelloCardFooter {
        TrelloCardFooter(lastActivity: lastActivity, url: url, isRefreshing: isLoading,
                         failure: refreshFailure, onRefresh: refresh)
    }

    /// The description saved with a description edit; nil for other kinds or a cleared description.
    private var editText: String? {
        guard activity.kind == .editedDescription else { return nil }
        return activity.detail.nilIfBlank
    }

    private func cached(shortLink: String) -> TrelloCardLookup? {
        guard !shortLink.isEmpty, let details = trello.cachedCardDetails(shortLink: shortLink) else { return nil }
        return .loaded(details)
    }

    /// The entry's own (validated) link, else the card's URL from Trello when it is an https trello.com link.
    private func openURL(_ details: TrelloCardDetails?) -> URL? {
        if let url = activity.cardURL { return url }
        guard let url = details?.url, url.scheme == "https", let host = url.host()?.lowercased(),
              host == "trello.com" || host.hasSuffix(".trello.com") else { return nil }
        return url
    }

    private func load(shortLink: String, forceRefresh: Bool) async {
        isLoading = true
        let result = await trello.cardDetails(shortLink: shortLink, forceRefresh: forceRefresh)
        // A newer load (refresh) owns `isLoading` now.
        guard !Task.isCancelled else { return }
        isLoading = false
        if case .unavailable(let reason) = result, case .some(.loaded(_)) = lookup {
            // Keep the card on screen; say why it couldn't be refreshed.
            refreshFailure = reason
        } else {
            lookup = result
            refreshFailure = nil
        }
    }

    private func refresh() {
        generation += 1
    }
}

/// Loaded card: heading, labels, "This edit", description, checklists, footer.
@MainActor
private struct TrelloCardDetailsView: View {
    @Environment(\.theme) private var theme
    let details: TrelloCardDetails
    let fallbackName: String
    let editText: String?
    let footer: TrelloCardFooter

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            TrelloCardHeading(details: details, fallbackName: fallbackName)
            if !details.labels.isEmpty {
                TrelloCardLabels(labels: details.labels)
            }
            if let editText {
                TrelloCardTextBlock(title: "This edit", text: editText, isQuoted: true)
            }
            TrelloCardTextBlock(title: editText == nil ? "Description" : "Description now",
                                text: details.description, isQuoted: false)
            TrelloCardChecklists(checklists: details.checklists)
            footer
        }
    }
}

/// Card name (headline), "Board › List", status chips (Archived / Due … / Done).
@MainActor
private struct TrelloCardHeading: View {
    @Environment(\.theme) private var theme
    let details: TrelloCardDetails
    let fallbackName: String

    var body: some View {
        let name = details.name.nilIfBlank ?? fallbackName.nilIfBlank ?? "Untitled card"
        let location = [details.boardName.trimmed, details.listName.trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " › ")
        let statuses = TrelloCardStatus.statuses(for: details)
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            Text(name)
                .font(theme.headlineFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !location.isEmpty {
                Text(location)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !statuses.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(statuses) { status in
                        TrelloStatusChip(status: status)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct TrelloCardStatus: Identifiable {
    enum Tone { case neutral, success }

    let id: String
    let title: String
    let systemImage: String
    let tone: Tone

    static func statuses(for details: TrelloCardDetails) -> [TrelloCardStatus] {
        var result: [TrelloCardStatus] = []
        if details.isArchived {
            result.append(TrelloCardStatus(id: "archived", title: "Archived", systemImage: "archivebox",
                                           tone: .neutral))
        }
        if let due = details.due {
            result.append(TrelloCardStatus(id: "due", title: "Due \(due.shortDateTime)", systemImage: "calendar",
                                           tone: .neutral))
            if details.isDueComplete {
                result.append(TrelloCardStatus(id: "done", title: "Done", systemImage: "checkmark.circle",
                                               tone: .success))
            }
        }
        return result
    }
}

@MainActor
private struct TrelloStatusChip: View {
    @Environment(\.theme) private var theme
    let status: TrelloCardStatus

    var body: some View {
        let tint = status.tone == .success ? theme.success : theme.textSecondary
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .accessibilityHidden(true)
            Text(status.title)
                .lineLimit(1)
        }
        .font(theme.labelFont)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.chipShape.fill(tint.opacity(theme.tintOpacity)))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct TrelloCardLabels: View {
    let labels: [TrelloCardDetails.Label]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                TrelloLabelChip(label: label)
            }
        }
    }
}

/// A Trello label: its color as a dot and a faint fill, and its name (or the color's name when it has none).
@MainActor
private struct TrelloLabelChip: View {
    @Environment(\.theme) private var theme
    let label: TrelloCardDetails.Label

    var body: some View {
        let hex = TrelloLabelColor.hex(for: label.color)
        let title = label.name.nilIfBlank ?? TrelloLabelColor.displayName(for: label.color)
        HStack(spacing: 4) {
            ColorDot(hex: hex, size: 7 * theme.textScale)
            Text(title)
                .font(theme.labelFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.chipShape.fill(Color(hex: hex).opacity(theme.tintOpacity * 1.5)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Label \(title)")
    }
}

/// Trello label color names (green … black, plus `_light` / `_dark`) → hex; anything else is neutral gray.
enum TrelloLabelColor {
    static let neutralHex = "#8E8E93"

    private struct Swatch {
        let normal: String
        let light: String
        let dark: String
    }

    private static let swatches: [String: Swatch] = [
        "green": Swatch(normal: "#4BCE97", light: "#BAF3DB", dark: "#1F845A"),
        "yellow": Swatch(normal: "#F5CD47", light: "#F8E6A0", dark: "#946F00"),
        "orange": Swatch(normal: "#FEA362", light: "#FEDEC8", dark: "#C25100"),
        "red": Swatch(normal: "#F87168", light: "#FFD5D2", dark: "#C9372C"),
        "purple": Swatch(normal: "#9F8FEF", light: "#DFD8FD", dark: "#6E5DC6"),
        "blue": Swatch(normal: "#579DFF", light: "#CCE0FF", dark: "#0C66E4"),
        "sky": Swatch(normal: "#6CC3E0", light: "#C6EDFB", dark: "#227D9B"),
        "lime": Swatch(normal: "#94C748", light: "#D3F1A7", dark: "#5B7F24"),
        "pink": Swatch(normal: "#E774BB", light: "#FDD0EC", dark: "#AE4787"),
        "black": Swatch(normal: "#8590A2", light: "#DCDFE4", dark: "#626F86"),
    ]

    static func hex(for color: String) -> String {
        let parts = color.trimmed.lowercased().split(separator: "_", maxSplits: 1).map(String.init)
        guard let base = parts.first, let swatch = swatches[base] else { return neutralHex }
        switch parts.count > 1 ? parts[1] : "" {
        case "light": return swatch.light
        case "dark": return swatch.dark
        default: return swatch.normal
        }
    }

    /// "green_dark" → "Green"; "" → "No color".
    static func displayName(for color: String) -> String {
        let base = color.trimmed.lowercased().split(separator: "_").first.map(String.init) ?? ""
        return base.isEmpty ? "No color" : base.capitalized
    }
}

/// A small caption title over a block of card text (markdown, inline only). `isQuoted`: a leading accent bar
/// ("This edit"). Blank text reads "No description."
@MainActor
private struct TrelloCardTextBlock: View {
    @Environment(\.theme) private var theme
    let title: String
    let text: String
    let isQuoted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            Text(title)
                .font(theme.captionFont.weight(.semibold))
                .foregroundStyle(theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            if text.isBlank {
                Text("No description.")
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textTertiary)
            } else if isQuoted {
                TrelloMarkdownText(text: text)
                    .padding(.leading, theme.spacingS + 2)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.accent.opacity(0.55))
                            .frame(width: 2)
                            .accessibilityHidden(true)
                    }
            } else {
                TrelloMarkdownText(text: text)
            }
        }
    }
}

/// Selectable, wrapping text; inline markdown (bold, italic, code, web links) when it parses, plain text otherwise.
@MainActor
private struct TrelloMarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(theme.calloutFont)
            .foregroundStyle(theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Links keep only http(s) and mailto targets (card text can come from anyone on the board).
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        let unsafeLinks = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            let scheme = url.scheme?.lowercased() ?? ""
            return ["https", "http", "mailto"].contains(scheme) ? nil : run.range
        }
        for range in unsafeLinks {
            result[range].link = nil
        }
        return result
    }
}

@MainActor
private struct TrelloCardChecklists: View {
    let checklists: [TrelloCardDetails.Checklist]

    var body: some View {
        ForEach(Array(checklists.enumerated()), id: \.offset) { _, checklist in
            TrelloChecklistView(checklist: checklist)
        }
    }
}

/// Checklist name + "n/m", then ✓ / ○ items.
@MainActor
private struct TrelloChecklistView: View {
    @Environment(\.theme) private var theme
    let checklist: TrelloCardDetails.Checklist

    var body: some View {
        let done = checklist.items.filter(\.isComplete).count
        let name = checklist.name.nilIfBlank ?? "Checklist"
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
                Text(name)
                    .font(theme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(done)/\(checklist.items.count)")
                    .font(theme.captionFont.monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(done) of \(checklist.items.count) done")
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(checklist.items.enumerated()), id: \.offset) { _, item in
                TrelloChecklistItemRow(item: item)
            }
        }
    }
}

@MainActor
private struct TrelloChecklistItemRow: View {
    @Environment(\.theme) private var theme
    let item: TrelloCardDetails.ChecklistItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS + 2) {
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                .font(theme.captionFont)
                .foregroundStyle(item.isComplete ? theme.success : theme.textTertiary)
            Text(item.name)
                .strikethrough(item.isComplete, color: theme.textTertiary)
                .font(theme.calloutFont)
                .foregroundStyle(item.isComplete ? theme.textSecondary : theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.isComplete ? "done" : "not done")")
    }
}

/// "Last activity 3 hours ago" · ( Open in Trello ) · refresh (spinner while loading); a refresh failure above it.
@MainActor
private struct TrelloCardFooter: View {
    @Environment(\.theme) private var theme
    let lastActivity: Date?
    let url: URL?
    let isRefreshing: Bool
    let failure: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingXS) {
            if let failure {
                TrelloCardMessage(systemImage: "exclamationmark.triangle", text: failure, isWarning: true)
            }
            HStack(spacing: theme.spacingS) {
                if let lastActivity {
                    Text("Last activity \(Self.relative(lastActivity))")
                        .font(theme.captionFont)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if let url {
                    Button("Open in Trello") { NSWorkspace.shared.open(url) }
                        .buttonStyle(QuietButtonStyle())
                        .controlSize(.small)
                }
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(IconButtonStyle(size: 22))
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh card")
        .help("Refresh")
    }

    /// "3 hours ago"; never "in 2 seconds" when the clocks disagree slightly.
    private static func relative(_ date: Date) -> String {
        let now = Date.now
        let shown = min(date, now)
        if now.timeIntervalSince(shown) < 60 {
            return "just now"
        }
        return shown.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

@MainActor
private struct TrelloCardLoadingLine: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.spacingS) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Loading card…")
                .font(theme.calloutFont)
                .foregroundStyle(theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One short line: deleted card, unavailable reason, refresh failure.
@MainActor
private struct TrelloCardMessage: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let text: String
    let isWarning: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS + 2) {
            Image(systemName: systemImage)
                .foregroundStyle(isWarning ? theme.warning : theme.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.calloutFont)
        .accessibilityElement(children: .combine)
    }
}

/// Open / copy / remove for a logged Trello entry (live list, review sheet, session detail).
@MainActor
enum TrelloActivityActions {
    /// Opens the card in the browser (nothing when the entry has no card link).
    static func open(_ activity: TrelloActivity) {
        guard ModelLiveness.isLive(activity), let url = activity.cardURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// The summary, plus the card link on a second line when there is one.
    static func copy(_ activity: TrelloActivity) {
        guard ModelLiveness.isLive(activity) else { return }
        var text = activity.summary
        if let url = activity.cardURL {
            text += "\n" + url.absoluteString
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Removes the entry from its session and saves (`SessionEditor.deleteTrelloActivity`, like the other child
    /// deletes; `SafeSave`: rolled back and reported on failure).
    static func remove(_ activity: TrelloActivity, in context: ModelContext) {
        SessionEditor.deleteTrelloActivity(activity, in: context)
    }
}
