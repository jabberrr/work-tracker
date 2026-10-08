import SwiftUI

// Settings rows that read as a sentence with the value highlighted:
//
//     Keep the latest 10 backups                         [-|+]
//     Ask “Still working?” after 10 hours                [-|+]
//     Opacity 95%                              ────●──────
//     Week starts on Monday ⌄
//
// The value is bold and in `theme.accent`. Everything is set in the inherited font (no monospaced digits,
// no `LabeledContent`), so the value shares the sentence's baseline and wraps with it.
// Native controls (Stepper, Slider) stay native and sit trailing.

/// "Keep the latest **10 backups**". One concatenated `Text`: prefix/suffix in textPrimary, value .bold() + theme.accent,
/// all in the inherited font, so it shares the baseline and wraps like a sentence. No monospacedDigit, no LabeledContent.
struct ValueSentence: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    private let prefix: String
    private let value: String
    private let suffix: String

    init(_ prefix: String, value: String, suffix: String = "") {
        self.prefix = prefix
        self.value = value
        self.suffix = suffix
    }

    var body: some View {
        sentence
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var sentence: Text {
        var text = Text(verbatim: "")
        if !prefix.isEmpty {
            text = Text(verbatim: prefix + " ").foregroundStyle(theme.textPrimary)
        }
        text = text + Text(verbatim: value).bold().foregroundStyle(theme.accent)
        if !suffix.isEmpty {
            text = text + Text(verbatim: " " + suffix).foregroundStyle(theme.textPrimary)
        }
        return text
    }
}

/// Row: ValueSentence … Spacer … native Stepper (labelsHidden). Row alignment .center. a11y: label prefix+suffix, value = formatted.
struct ValueStepper: View {
    @Environment(\.theme) private var theme
    private let prefix: String
    private let suffix: String
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String

    init(_ prefix: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1,
         suffix: String = "", format: @escaping (Double) -> String) {
        self.prefix = prefix
        self.suffix = suffix
        self.value = value
        self.range = range
        self.step = step
        self.format = format
    }

    init(_ prefix: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
         suffix: String = "", format: @escaping (Int) -> String) {
        self.prefix = prefix
        self.suffix = suffix
        self.value = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        self.format = { format(Int($0.rounded())) }
    }

    var body: some View {
        let formatted = format(value.wrappedValue)
        HStack(alignment: .center, spacing: theme.spacingM) {
            ValueSentence(prefix, value: formatted, suffix: suffix)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper(value: value, in: range, step: step) {
                Text(SettingValueA11y.label(prefix, suffix))
            }
            .labelsHidden()
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingValueA11y.label(prefix, suffix))
        .accessibilityValue(formatted)
        .accessibilityAdjustableAction { direction in
            SettingValueA11y.adjust(value, in: range, by: step, direction: direction)
        }
    }
}

/// Row: ValueSentence … Spacer … Slider (labelsHidden, width 200).
struct ValueSlider: View {
    @Environment(\.theme) private var theme
    private let prefix: String
    private let suffix: String
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String

    init(_ prefix: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         suffix: String = "", format: @escaping (Double) -> String) {
        self.prefix = prefix
        self.suffix = suffix
        self.value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        let formatted = format(value.wrappedValue)
        HStack(alignment: .center, spacing: theme.spacingM) {
            ValueSentence(prefix, value: formatted, suffix: suffix)
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: value, in: range, step: step) {
                Text(SettingValueA11y.label(prefix, suffix))
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingValueA11y.label(prefix, suffix))
        .accessibilityValue(formatted)
        .accessibilityAdjustableAction { direction in
            SettingValueA11y.adjust(value, in: range, by: step, direction: direction)
        }
    }
}

/// "Week starts on **Monday** ⌄". The prefix is plain Text. The value + small chevron (bold, accent) is a plain Button
/// that opens a popover listing `options` (checkmark on the selected one; click or Return selects and closes).
/// The HStack uses .firstTextBaseline with the same font.
struct ValuePicker<Option: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var selection: Option
    private let prefix: String
    private let suffix: String
    private let options: [Option]
    private let title: (Option) -> String
    @State private var isPresented = false
    @State private var isHovering = false

    init(_ prefix: String, selection: Binding<Option>, options: [Option], suffix: String = "",
         title: @escaping (Option) -> String) {
        self.prefix = prefix
        self._selection = selection
        self.options = options
        self.suffix = suffix
        self.title = title
    }

    var body: some View {
        let current = title(selection)
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXS) {
            if !prefix.isEmpty {
                Text(verbatim: prefix)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityHidden(true)
            }
            Button {
                isPresented.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: current)
                        .bold()
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .fontWeight(.bold)
                }
                .foregroundStyle(theme.accent)
                .opacity(isHovering ? 0.75 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = isEnabled && $0 }
            .accessibilityLabel(SettingValueA11y.label(prefix, suffix))
            .accessibilityValue(current)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ValuePickerList(options: options, selected: selection, title: title) { option in
                    selection = option
                    isPresented = false
                }
                .environment(\.theme, theme)
                .tint(theme.accent)
            }
            if !suffix.isEmpty {
                Text(verbatim: suffix)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Implementation

/// The popover list of a `ValuePicker`. ↑/↓ move the highlight, Return or Space picks it, Esc closes (system).
private struct ValuePickerList<Option: Hashable>: View {
    @Environment(\.theme) private var theme
    private let options: [Option]
    private let selected: Option
    private let title: (Option) -> String
    private let onSelect: (Option) -> Void
    @State private var highlighted: Int
    @FocusState private var isFocused: Bool

    init(options: [Option], selected: Option, title: @escaping (Option) -> String,
         onSelect: @escaping (Option) -> Void) {
        self.options = options
        self.selected = selected
        self.title = title
        self.onSelect = onSelect
        self._highlighted = State(initialValue: options.firstIndex(of: selected) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isSelected = option == selected
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: theme.spacingS) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10 * theme.textScale, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .opacity(isSelected ? 1 : 0)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text(verbatim: title(option))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(ValuePickerRowStyle(isHighlighted: index == highlighted))
                .onHover { if $0 { highlighted = index } }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(minWidth: 160)
        .background(theme.elevatedSurface)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            move(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            pickHighlighted()
            return .handled
        }
        .onKeyPress(.space) {
            pickHighlighted()
            return .handled
        }
        .onAppear {
            // Let the popover window become key before taking focus.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                isFocused = true
            }
        }
    }

    private func move(by delta: Int) {
        guard !options.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), options.count - 1)
    }

    private func pickHighlighted() {
        guard options.indices.contains(highlighted) else { return }
        onSelect(options[highlighted])
    }
}

/// Full-width menu-like row: hover/highlight fill, pressed fill.
private struct ValuePickerRowStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        ValuePickerRowBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct ValuePickerRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        configuration.label
            .font(theme.bodyFont)
            .padding(.horizontal, theme.spacingS)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.accent.opacity(0.18)
                          : (isHighlighted ? theme.textPrimary.opacity(0.07) : Color.clear))
            )
            .contentShape(Rectangle())
    }
}

/// Shared accessibility helpers for the value rows.
private enum SettingValueA11y {
    /// "Keep the latest backups": prefix and suffix, without the value.
    static func label(_ prefix: String, _ suffix: String) -> String {
        [prefix, suffix]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func adjust(_ value: Binding<Double>, in range: ClosedRange<Double>, by step: Double,
                       direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment:
            value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
        case .decrement:
            value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
        @unknown default:
            break
        }
    }
}

#Preview("Value controls") {
    Form {
        ValueStepper("Keep the latest", value: .constant(10), in: 1...100,
                     format: { "\($0) \($0 == 1 ? "backup" : "backups")" })
        ValueStepper("Daily goal", value: .constant(4.0), in: 0...16, step: 0.5,
                     format: { $0 > 0 ? "\(Int($0))h" : "Off" })
        ValueSlider("Opacity", value: .constant(0.95), in: 0.4...1.0, step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))%" })
        ValuePicker("Week starts on", selection: .constant(true), options: [true, false],
                    title: { $0 ? "Monday" : "Sunday" })
    }
    .formStyle(.grouped)
    .frame(width: 520)
}
