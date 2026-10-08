import SwiftData
import SwiftUI

/// The "takeaway for next time" editor, shared by the end-of-session sheet and Session detail's LearningsEditor:
/// one line (`session.overlaySummary`) shown in the overlay and menu bar during the next session, the
/// "Show in overlay & menu bar" toggle (`session.showInOverlay`), a 140-character guidance counter and a short
/// hint (nothing to show yet / too long for the overlay).
///
/// Typing a first takeaway turns the toggle on, unless the user already set the toggle themselves here.
/// Edits write straight to the model; the host saves (the sheet on Save, LearningsEditor on its own triggers).
/// `onCommit` runs on Return and when the field loses focus. No title: the host labels it.
/// Renders nothing once the session is deleted.
@MainActor
struct TakeawayField: View {
    @Environment(\.theme) private var theme

    @Bindable private var session: WorkSession
    private let onCommit: () -> Void

    /// The user changed the toggle in this editor: never override their choice.
    @State private var userSetToggle = false
    @FocusState private var isFocused: Bool

    static let guidanceLength = 140

    init(session: WorkSession, onCommit: @escaping () -> Void = {}) {
        self._session = Bindable(wrappedValue: session)
        self.onCommit = onCommit
    }

    var body: some View {
        if ModelLiveness.isLive(session) {
            content
        }
    }

    private var content: some View {
        let count = session.overlaySummary.trimmed.count
        let limit = Self.guidanceLength
        let isOver = count > limit
        return VStack(alignment: .leading, spacing: theme.spacingXS) {
            TextField("Takeaway", text: $session.overlaySummary, prompt: Text("One line for next time"))
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .focused($isFocused)
                .onSubmit(onCommit)
                .insetField(isFocused: isFocused)
                .accessibilityLabel("Takeaway for next time")
            HStack(spacing: theme.spacingS) {
                Toggle("Show in overlay & menu bar", isOn: toggleBinding)
                    .toggleStyle(.checkbox)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: theme.spacingS)
                if count > 0 {
                    Text("\(count)/\(limit)")
                        .font(theme.captionFont.monospacedDigit())
                        .foregroundStyle(isOver ? theme.warning : theme.textTertiary)
                        .help("Suggested length")
                        .accessibilityLabel("\(count) of \(limit) suggested characters")
                }
            }
            if session.showInOverlay && session.takeawayText == nil {
                Text("Add a takeaway or learning to show.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isOver {
                Text("Long takeaways are cut off in the overlay.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: session.overlaySummary) { oldValue, newValue in
            guard ModelLiveness.isLive(session), !userSetToggle else { return }
            if oldValue.isBlank && !newValue.isBlank && !session.showInOverlay {
                session.showInOverlay = true
            }
        }
        .onChange(of: isFocused) { wasFocused, _ in
            if wasFocused { onCommit() }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { ModelLiveness.isLive(session) && session.showInOverlay },
            set: { newValue in
                guard ModelLiveness.isLive(session) else { return }
                userSetToggle = true
                session.showInOverlay = newValue
            }
        )
    }
}
