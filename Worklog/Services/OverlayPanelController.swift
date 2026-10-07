import AppKit
import Observation
import SwiftUI

/// Borderless, non-activating floating panel. It can become key (so the note field accepts typing) without
/// activating the app or becoming main.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }    // lets the note TextField receive input
    override var canBecomeMain: Bool { false }
}

/// The overlay's SwiftUI host. `mouseDownCanMoveWindow` lets a drag on any non-interactive area move the panel
/// (`isMovableByWindowBackground`); SwiftUI controls and the note field still receive their clicks.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Owns the floating overlay panel. `settings.overlayEnabled` is the source of truth for visibility.
@MainActor @Observable
final class OverlayPanelController {
    private(set) var isVisible = false

    private static let autosaveName = "WorklogOverlay"
    private static let screenMargin: CGFloat = 20

    private let settings: AppSettings
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var panel: OverlayPanel?
    @ObservationIgnored private var isInstalled = false
    @ObservationIgnored private var hasLaunched = false
    @ObservationIgnored private var launchObserver: NSObjectProtocol?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    /// Top-left corner kept fixed while SwiftUI resizes the panel to its ideal size.
    @ObservationIgnored private var anchorTopLeft: NSPoint?
    @ObservationIgnored private var isAdjustingFrame = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Builds the panel (lazily, the first time it must be shown) and keeps it in sync with the overlay settings
    /// and `engine.isActive` via withObservationTracking:
    /// - alphaValue = overlayOpacity
    /// - level = overlayAlwaysOnTop ? .floating : .normal
    /// - collectionBehavior = overlayShowOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    /// - visible = overlayEnabled && !(overlayHideWhenIdle && !engine.isActive)
    /// Nothing is ordered on screen before the app has finished launching.
    func install(services: AppServices) {
        guard !isInstalled else { return }
        isInstalled = true
        self.services = services
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.applicationDidFinishLaunching() }
        }
        observe()
    }

    /// Called by AppDelegate.applicationDidFinishLaunching (also observed automatically): from now on the panel may
    /// be ordered front. Shows the overlay if `settings.overlayEnabled`.
    func applicationDidFinishLaunching() {
        guard !hasLaunched else { return }
        hasLaunched = true
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        apply()
    }

    func show() { settings.overlayEnabled = true }     // settings.overlayEnabled = true
    func hide() { settings.overlayEnabled = false }    // settings.overlayEnabled = false
    func toggle() { settings.overlayEnabled.toggle() }

    // MARK: - Private

    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// Reads every observed input (so withObservationTracking registers them), then updates the panel.
    private func apply() {
        let opacity = settings.overlayOpacity
        let alwaysOnTop = settings.overlayAlwaysOnTop
        let allSpaces = settings.overlayShowOnAllSpaces
        let enabled = settings.overlayEnabled
        let hideWhenIdle = settings.overlayHideWhenIdle
        let engineActive = services?.engine.isActive ?? false
        let shouldShow = enabled && !(hideWhenIdle && !engineActive)

        guard isInstalled, hasLaunched else { return }

        if shouldShow && panel == nil {
            buildPanel()
        }
        guard let panel else {
            isVisible = false
            return
        }
        panel.alphaValue = CGFloat(opacity)
        panel.level = alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]

        if shouldShow {
            if !panel.isVisible {
                keepOnScreen(panel)
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        isVisible = shouldShow
    }

    private func buildPanel() {
        guard let services else { return }
        // OverlayView has a fixed width and a fixed (intrinsic) height, so the hosting view's min/max-size
        // constraints pin the panel's content size to the SwiftUI content as sections appear and disappear.
        let hostingView = OverlayHostingView(rootView: OverlayView().withAppServices(services))
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.title = "Worklog Overlay"
        panel.contentView = hostingView
        let fitting = hostingView.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }

        if !panel.setFrameUsingName(Self.autosaveName) {
            positionTopRight(panel)
        }
        _ = panel.setFrameAutosaveName(Self.autosaveName)
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)

        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.panelDidResize() }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.panelDidMove() }
        })
        self.panel = panel
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - Self.screenMargin,
                             y: visible.maxY - size.height - Self.screenMargin)
        panel.setFrameOrigin(origin)
    }

    /// If the saved position is no longer on any screen (monitor unplugged), move back to the top-right.
    private func keepOnScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onScreen {
            positionTopRight(panel)
            anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
    }

    /// SwiftUI changes the height as sections appear/disappear; keep the top-left corner where the user put it.
    private func panelDidResize() {
        guard let panel, let anchor = anchorTopLeft, !isAdjustingFrame else { return }
        let target = NSPoint(x: anchor.x, y: anchor.y - panel.frame.height)
        guard panel.frame.origin != target else { return }
        isAdjustingFrame = true
        panel.setFrameOrigin(target)
        isAdjustingFrame = false
    }

    private func panelDidMove() {
        guard let panel, !isAdjustingFrame else { return }
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }
}
