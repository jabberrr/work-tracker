import SwiftUI

enum BannerStyle {
    case info, success, warning, error
}

/// A one-line (wrapping) message bar placed at the top of a pane: status icon, message,
/// optional action button, optional dismiss (×). Tinted with the status color at low opacity.
/// Copy: one short sentence + an action (DESIGN §12).
struct InlineBanner: View {
    @Environment(\.theme) private var theme
    private let message: String
    private let systemImage: String?
    private let style: BannerStyle
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let onDismiss: (() -> Void)?

    init(_ message: String, systemImage: String? = nil, style: BannerStyle = .info,
         actionTitle: String? = nil, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusM, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingS) {
            Image(systemName: systemImage ?? defaultSymbol)
                .font(theme.bodyFont.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(theme.calloutFont)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(styleName): \(message)")
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle())
                    .controlSize(.small)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 20))
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background {
            ZStack {
                shape.fill(theme.surface)
                shape.fill(tint.opacity(theme.tintOpacity))
            }
        }
        .overlay {
            shape.strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch style {
        case .info: return theme.accent
        case .success: return theme.success
        case .warning: return theme.warning
        case .error: return theme.danger
        }
    }

    private var defaultSymbol: String {
        switch style {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.octagon"
        }
    }

    private var styleName: String {
        switch style {
        case .info: return "Info"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

#Preview("InlineBanner") {
    VStack(spacing: 10) {
        InlineBanner("iCloud sync failed; changes kept on this Mac.", actionTitle: "Details…",
                     action: {}, onDismiss: {})
        InlineBanner("Paused while your Mac slept.", style: .warning,
                     actionTitle: "Resume", action: {}, onDismiss: {})
        InlineBanner("Your data couldn’t be opened. Changes won’t be saved.", style: .error,
                     actionTitle: "Restore…", action: {})
    }
    .padding(24)
    .frame(width: 560)
}
