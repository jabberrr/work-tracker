import SwiftUI

/// Centered, quiet empty state: a light symbol, a title in the display face (≤ 4 words), an optional
/// one-sentence message (≤ 10 words) and an optional single action (primary style, ≤ 3 words). Copy: DESIGN §12.
/// Fills the available space; place it as the whole content of an empty pane.
struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    private let title: String
    private let systemImage: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(title: String, systemImage: String, message: String? = nil,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: theme.spacingM) {
            Image(systemName: systemImage)
                .font(.system(size: 34 * theme.textScale, weight: .light))
                .foregroundStyle(theme.textTertiary)
                .padding(.bottom, theme.spacingXS)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.titleFont)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(theme.calloutFont)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, theme.spacingS)
            }
        }
        .padding(theme.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("EmptyStateView") {
    EmptyStateView(title: "No sessions yet",
                   systemImage: "clock",
                   message: "Finished sessions appear here.",
                   actionTitle: "Start session") {}
        .frame(width: 480, height: 360)
        .themedBackground()
}
