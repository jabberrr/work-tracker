import SwiftUI
import AppKit

/// Key-cap field.
/// - Idle: displayString in a keycap pill (insetSurface, separator border, radiusS, bodyFont .medium,
///   min width 96, height 24), or "None" in textTertiary.
/// - Click → recording: accent 1.5 pt border, "Type shortcut…" (textSecondary), live modifier glyphs while held
///   (flagsChanged). Tooltip "Esc cancels, ⌫ clears".
/// - While recording, an NSEvent local monitor ([.keyDown, .flagsChanged]) swallows events (returns nil):
///   - Esc without modifiers → cancel
///   - ⌫ or ⌦ without modifiers → onClear()
///   - otherwise StoredShortcut(event:) → onRecord (unsupported keys: NSSound.beep(), keep recording)
/// - Recording also ends on a second click, the recorder's OWN window resigning key (other windows — the overlay,
///   the menu bar panel — don't count), onDisappear, or when another recorder begins (one at a time).
/// - The monitor lives in a @State reference object; it is removed on every exit path and in deinit.
///
/// (Extra) A click anywhere else in the app also ends recording (the click itself goes through), so keys are
/// never swallowed by a recorder the user has moved away from.
///
/// The recorder doesn't validate: the caller passes the result to `ShortcutStore.set(_:for:)` and shows its
/// `ShortcutValidation.message` under the row.
struct ShortcutRecorder: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var recorder = ShortcutRecorderMonitor()
    @State private var isRecording = false
    @State private var heldModifiers = ""
    @State private var isHovering = false

    private let shortcut: StoredShortcut?
    private let accessibilityName: String
    private let onRecord: (StoredShortcut) -> Void
    private let onClear: () -> Void

    init(shortcut: StoredShortcut?, accessibilityName: String,
         onRecord: @escaping (StoredShortcut) -> Void, onClear: @escaping () -> Void) {
        self.shortcut = shortcut
        self.accessibilityName = accessibilityName
        self.onRecord = onRecord
        self.onClear = onClear
    }

    /// The assigned shortcut's glyphs, or nil when unassigned.
    private var assignedDisplay: String? {
        guard let shortcut, !shortcut.isNone else { return nil }
        let display = shortcut.displayString
        return display.isEmpty ? nil : display
    }

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            keycap
        }
        .buttonStyle(.plain)
        .background(ShortcutRecorderWindowReader(monitor: recorder))
        .onHover { isHovering = isEnabled && $0 }
        .help(isRecording ? "Esc cancels, ⌫ clears" : "Record shortcut")
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isRecording ? "Recording" : (assignedDisplay ?? "None"))
        .accessibilityHint(isRecording ? "Escape cancels, Delete clears." : "Records a new shortcut.")
        .onDisappear { recorder.stop() }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { recorder.stop() }
        }
    }

    // MARK: Appearance

    private var keycap: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusS, style: .continuous)
        return ZStack {
            // Reserves the widest state's width so the row doesn't shift when recording starts.
            Text("Type shortcut…")
                .font(theme.bodyFont.weight(.medium))
                .hidden()
                .accessibilityHidden(true)
            keycapLabel
        }
        .lineLimit(1)
        .padding(.horizontal, theme.spacingS)
        .frame(minWidth: 96, minHeight: 24)
        .background {
            ZStack {
                shape.fill(theme.insetSurface)
                if isHovering && !isRecording {
                    shape.fill(theme.textPrimary.opacity(0.04))
                }
            }
        }
        .overlay {
            shape.strokeBorder(isRecording ? theme.accent : theme.separator,
                               lineWidth: isRecording ? 1.5 : 1)
        }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.45)
    }

    @ViewBuilder private var keycapLabel: some View {
        if isRecording {
            if heldModifiers.isEmpty {
                Text("Type shortcut…")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text(verbatim: heldModifiers)
                    .font(theme.bodyFont.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
            }
        } else if let display = assignedDisplay {
            Text(verbatim: display)
                .font(theme.bodyFont.weight(.medium))
                .foregroundStyle(theme.textPrimary)
        } else {
            Text("None")
                .font(theme.bodyFont)
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: Recording

    @MainActor
    private func toggleRecording() {
        if isRecording {
            recorder.stop()
            return
        }
        // The mouse-down of this very click already ended a recording (see ShortcutRecorderMonitor): stay stopped.
        guard !recorder.consumeEndedByClick(matching: NSApp.currentEvent) else { return }
        heldModifiers = ""
        // The recorder's own window (never "whichever window is key"): only it resigning key ends recording.
        recorder.start(
            in: recorder.hostWindow ?? NSApp.currentEvent?.window,
            onKeyEvent: { event in handle(event) },
            onEnd: {
                isRecording = false
                heldModifiers = ""
            }
        )
        isRecording = true
    }

    /// Called for every keyDown / flagsChanged while recording (the event is swallowed).
    @MainActor
    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.type == .flagsChanged {
            heldModifiers = Self.glyphs(for: modifiers)
            return
        }
        guard event.type == .keyDown else { return }
        if modifiers.isEmpty {
            switch event.keyCode {
            case 53:            // Esc → cancel
                recorder.stop()
                return
            case 51, 117:       // Delete (⌫), Forward Delete (⌦) → clear
                recorder.stop()
                onClear()
                return
            default:
                break
            }
        }
        guard let recorded = StoredShortcut(event: event), !recorded.isNone else {
            NSSound.beep()
            return
        }
        recorder.stop()
        onRecord(recorded)
    }

    /// "⌃⌥⇧⌘" order, for the modifiers held while recording.
    private static func glyphs(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }
}

/// ↺ icon (arrow.counterclockwise), IconButtonStyle(size: 22), disabled when isDefault, .help("Reset").
struct ResetToDefaultButton: View {
    private let isDefault: Bool
    private let accessibilityLabel: String
    private let action: () -> Void

    init(isDefault: Bool, accessibilityLabel: String, action: @escaping () -> Void) {
        self.isDefault = isDefault
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(IconButtonStyle(size: 22))
        .disabled(isDefault)
        .help("Reset")
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Monitor

/// Owns the event monitor and the resign-key observer of one recorder. Only one recorder records at a time:
/// starting one stops the other. Every exit path goes through `stop()`, which removes both and calls `onEnd`
/// once; `deinit` removes them too.
///
/// The class is not actor-isolated on purpose (so `deinit` can clean up); it is only used on the main thread
/// (views, the local event monitor and a `.main`-queue observer). The shared `active` slot and the methods that
/// touch it are `@MainActor`.
/// Only ever used on the main thread (AppKit event monitor + main-queue observer), so it is marked
/// `@unchecked Sendable` to let the @Sendable callbacks hold it; `deinit` must stay nonisolated to remove the monitor.
private final class ShortcutRecorderMonitor: @unchecked Sendable {
    @MainActor private static weak var active: ShortcutRecorderMonitor?

    /// The window hosting the recorder (set by `ShortcutRecorderWindowReader`).
    weak var hostWindow: NSWindow?

    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onEnd: (() -> Void)?
    /// The mouse-down that last ended recording: when, in which window, where.
    private var endingClick: (time: Date, windowNumber: Int, location: NSPoint)?

    /// True when `event` is the mouse-up of the click whose mouse-down just ended recording, so that click's
    /// button action doesn't start recording again (a second click ends recording). Keyboard activation and
    /// later clicks start normally. Clears the stored click.
    func consumeEndedByClick(matching event: NSEvent?) -> Bool {
        defer { endingClick = nil }
        guard let click = endingClick, Date().timeIntervalSince(click.time) < 2,
              let event, event.type == .leftMouseUp, event.windowNumber == click.windowNumber else {
            return false
        }
        let dx = event.locationInWindow.x - click.location.x
        let dy = event.locationInWindow.y - click.location.y
        return dx * dx + dy * dy < 100
    }

    /// `window`: the recorder's own window; only its resign-key ends recording. Nil → no resign-key observer
    /// (clicks, Esc, onDisappear and other recorders still end it).
    @MainActor
    func start(in window: NSWindow?, onKeyEvent: @escaping (NSEvent) -> Void, onEnd: @escaping () -> Void) {
        if let other = Self.active, other !== self {
            other.stop()
        }
        stop()
        endingClick = nil
        self.onEnd = onEnd
        Self.active = self

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown, .flagsChanged:
                onKeyEvent(event)
                return nil
            default:
                // A click (on this recorder or anywhere else) ends recording and goes through.
                self.endingClick = (Date(), event.windowNumber, event.locationInWindow)
                MainActor.assumeIsolated { () -> Void in self.stop() }
                return event
            }
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { () -> Void in self?.stop() }
            }
        }
    }

    /// Removes the monitor and observer and calls `onEnd` (once). Safe to call when not recording.
    @MainActor
    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if Self.active === self {
            Self.active = nil
        }
        let end = onEnd
        onEnd = nil
        end?()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }
}

/// Reports the window hosting a `ShortcutRecorder` to its monitor (kept current as the view moves windows).
private struct ShortcutRecorderWindowReader: NSViewRepresentable {
    let monitor: ShortcutRecorderMonitor

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.monitor = monitor
        if let window = nsView.window {
            monitor.hostWindow = window
        }
    }

    final class ReaderView: NSView {
        weak var monitor: ShortcutRecorderMonitor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor?.hostWindow = window
        }

        /// Layout only: never takes clicks from the key cap.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
