import Foundation

/// Build-time Trello settings. `apiKey` is the developer's PUBLIC Trello API key (Power-Up admin → the integration →
/// API key; see README "Trello"). It identifies the app to Trello and is not a secret; the user's token is (Keychain,
/// `TrelloService`). Empty key → Trello is off in this build (`TrelloService.isConfigured == false`).
enum TrelloConfig {
    static let apiKey = ""
    /// Shown by Trello on the authorization page.
    static let appName = "Diptychon"
    /// `ASWebAuthenticationSession` callback: diptychon-trello://auth#token=…
    static let callbackScheme = "diptychon-trello"
}
