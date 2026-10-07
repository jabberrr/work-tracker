import SwiftUI

/// Inset search field: magnifier, plain text field, clear (×) button when non-empty.
/// Esc clears the text (when empty, Esc passes through to close a popover/sheet). The border turns accent while focused.
/// To focus it from outside (⌘F), use the extra `init(text:prompt:isFocused:)` with your own @FocusState.
struct SearchField: View {
    @Environment(\.theme) private var theme
    @Binding private var text: String
    private let prompt: String
    private let externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    init(text: Binding<String>, prompt: String = "Search") {
        self._text = text
        self.prompt = prompt
        self.externalFocus = nil
    }

    /// (Extra) Focus controlled by the caller: `@FocusState var searchFocused: Bool` →
    /// `SearchField(text: $query, prompt: "Search", isFocused: $searchFocused)`.
    init(text: Binding<String>, prompt: String = "Search", isFocused: FocusState<Bool>.Binding) {
        self._text = text
        self.prompt = prompt
        self.externalFocus = isFocused
    }

    private var focusBinding: FocusState<Bool>.Binding { externalFocus ?? $internalFocus }
    private var isFocused: Bool { focusBinding.wrappedValue }

    /// Clear on Esc; nil when already empty so Esc propagates (closes popovers/sheets).
    private var escapeAction: (() -> Void)? {
        guard !text.isEmpty else { return nil }
        let binding = $text
        return { binding.wrappedValue = "" }
    }

    var body: some View {
        HStack(spacing: theme.spacingXS + 2) {
            Image(systemName: "magnifyingglass")
                .font(theme.calloutFont.weight(.medium))
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.textPrimary)
                .focused(focusBinding)
                .onExitCommand(perform: escapeAction)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(theme.calloutFont)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .insetField(isFocused: isFocused)
    }
}
