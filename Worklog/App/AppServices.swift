import Foundation
import SwiftData
import SwiftUI

/// The app's service graph. One shared instance backs every scene, the menu bar extra and the overlay.
@MainActor
final class AppServices {
    /// The real app. Under XCTest the shared instance is in-memory so tests never touch the user's store.
    static let shared = AppServices(inMemory: AppServices.isRunningUnitTests)
    static let preview = AppServices(inMemory: true)   // populated by PreviewData

    let settings: AppSettings
    let persistence: PersistenceController
    let themeManager: ThemeManager
    let auth: AuthService
    let router: WindowRouter
    let engine: SessionEngine
    let exporter: ExportService
    let backups: BackupService
    let overlay: OverlayPanelController
    var container: ModelContainer { persistence.container }

    /// Order: settings → persistence(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory:) → themeManager → auth →
    /// router → engine(context: mainContext) → exporter → backups → overlay(settings:);
    /// SeedData.seedIfNeeded + deduplicate (or PreviewData.populate if inMemory);
    /// engine.restoreActiveSession(); overlay.install(services: self).
    ///
    /// In-memory instances (previews/tests) use a separate UserDefaults suite (emptied at creation) so they never read or change
    /// the user's preferences, and they don't install the overlay panel.
    init(inMemory: Bool = false) {
        let defaults: UserDefaults = inMemory ? Self.makeEphemeralDefaults() : .standard
        settings = AppSettings(defaults: defaults)
        persistence = PersistenceController(cloudSyncEnabled: settings.iCloudSyncEnabled, inMemory: inMemory)
        themeManager = ThemeManager(defaults: defaults)
        auth = AuthService()
        router = WindowRouter()
        engine = SessionEngine(context: persistence.mainContext, settings: settings)
        exporter = ExportService(container: persistence.container)
        backups = BackupService(exporter: exporter, settings: settings)
        overlay = OverlayPanelController(settings: settings)

        let context = persistence.mainContext
        if inMemory {
            PreviewData.populate(context)
        } else {
            SeedData.seedIfNeeded(in: context)
            SeedData.deduplicate(in: context)
        }
        engine.restoreActiveSession()
        if !inMemory {
            overlay.install(services: self)
        }
    }

    /// True when hosted by XCTest.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeEphemeralDefaults() -> UserDefaults {
        let suiteName = "\(AppConstants.bundleID).ephemeral"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return .standard }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension View {
    /// Injects every service + modelContainer + theme. Apply to EVERY scene root and to the overlay hosting view.
    @MainActor
    func withAppServices(_ services: AppServices) -> some View {
        self.environment(services.settings)
            .environment(services.persistence)
            .environment(services.themeManager)
            .environment(services.auth)
            .environment(services.router)
            .environment(services.engine)
            .environment(services.exporter)
            .environment(services.backups)
            .environment(services.overlay)
            .modelContainer(services.container)
            .worklogThemed(services.themeManager)
    }
}
