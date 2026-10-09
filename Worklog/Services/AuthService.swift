import AuthenticationServices
import Foundation
import Observation

enum AuthState: Equatable {
    case unknown
    case signedOut                     // → RootView shows WelcomeView
    case guest                         // "Continue without signing in"
    case signedIn(userID: String)
}

/// Sign in with Apple as the app's identity gate. iCloud sync is independent of this (it uses the Mac's iCloud
/// account). Signing out never deletes data.
@MainActor @Observable
final class AuthService {
    private(set) var state: AuthState = .unknown
    /// Apple only returns name/email on the first sign-in → stored in Keychain per Apple user ID and kept across
    /// sign-out, so signing back in with the same Apple ID shows the name again.
    private(set) var displayName: String? = nil
    private(set) var email: String? = nil
    var lastError: String? = nil

    /// state is .signedIn
    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// Whether this build has the Sign in with Apple entitlement (Debug and App Store/TestFlight builds do; a build
    /// signed without it — e.g. Developer ID, where Apple doesn't offer the capability — skips all sign-in UI).
    static var isSignInAvailable: Bool { Entitlements.hasSignInWithApple }

    /// state == .signedOut, and only when Sign in with Apple is available (otherwise there is nothing to gate on).
    var needsWelcome: Bool { state == .signedOut && AuthService.isSignInAvailable }

    private enum Keys {
        static let userID = "appleUserID"
        /// Pre-1.0 unkeyed items (migrated to the per-user keys on launch).
        static let legacyUserName = "appleUserName"
        static let legacyUserEmail = "appleUserEmail"
        static let guestMode = "auth.guestMode"

        static func userName(_ userID: String) -> String { "appleUserName." + userID }
        static func userEmail(_ userID: String) -> String { "appleUserEmail." + userID }
    }

    private let keychain: KeychainStore
    @ObservationIgnored private var revocationObserver: NSObjectProtocol?

    /// Initial state, set synchronously in init:
    /// - Keychain "appleUserID" exists → .signedIn (optimistic).
    /// - Else UserDefaults "auth.guestMode" == true → .guest.
    /// - Else → .signedOut.
    /// Also observes ASAuthorizationAppleIDProvider.credentialRevokedNotification → signOut().
    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        if let userID = keychain.string(for: Keys.userID), !userID.isEmpty {
            AuthService.migrateLegacyProfile(to: userID, keychain: keychain)
            state = .signedIn(userID: userID)
            displayName = keychain.string(for: Keys.userName(userID))
            email = keychain.string(for: Keys.userEmail(userID))
        } else if UserDefaults.standard.bool(forKey: Keys.guestMode) {
            state = .guest
        } else {
            state = .signedOut
        }

        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.auth.info("Apple ID credential revoked")
                self?.signOut()
            }
        }
    }

    /// Verifies the stored ID via ASAuthorizationAppleIDProvider().credentialState(forUserID:);
    /// .revoked/.notFound → signOut(). Network/entitlement errors keep the current state. Called at launch.
    func checkCredentialState() async {
        guard case .signedIn(let userID) = state else { return }
        guard Entitlements.hasSignInWithApple else {
            Log.auth.info("Skipping credential check: Sign in with Apple entitlement missing")
            return
        }
        do {
            let credentialState = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            // The user may have signed out/in while we were waiting.
            guard state == .signedIn(userID: userID) else { return }
            switch credentialState {
            case .revoked, .notFound:
                Log.auth.info("Apple ID credential no longer valid; signing out")
                signOut()
            case .authorized, .transferred:
                break
            @unknown default:
                break
            }
        } catch {
            Log.auth.error("Credential state check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// For SignInWithAppleButton(onRequest:): request.requestedScopes = [.fullName, .email].
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// For SignInWithAppleButton(onCompletion:). Success: store user, fullName (formatted), email in Keychain,
    /// clear guest flag, state = .signedIn. Failure (not canceled): lastError = message
    /// (hint when !Entitlements.hasSignInWithApple). ASAuthorizationError.canceled → ignore.
    func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Unexpected sign-in credential; try again."
                return
            }
            let userID = credential.user
            keychain.set(userID, for: Keys.userID)

            // Name/email are stored per Apple user ID, so a different Apple ID never shows someone else's name.
            var name = keychain.string(for: Keys.userName(userID))
            var mail = keychain.string(for: Keys.userEmail(userID))
            if let nameComponents = credential.fullName {
                let formatted = PersonNameComponentsFormatter.localizedString(from: nameComponents, style: .default)
                if let fresh = formatted.nilIfBlank {
                    keychain.set(fresh, for: Keys.userName(userID))
                    name = fresh
                }
            }
            if let fresh = credential.email?.nilIfBlank {
                keychain.set(fresh, for: Keys.userEmail(userID))
                mail = fresh
            }
            displayName = name
            email = mail

            UserDefaults.standard.set(false, forKey: Keys.guestMode)
            lastError = nil
            state = .signedIn(userID: userID)
            Log.auth.info("Signed in with Apple")

        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain, nsError.code == ASAuthorizationError.Code.canceled.rawValue {
                return
            }
            if !Entitlements.hasSignInWithApple {
                lastError = "Sign in with Apple isn\u{2019}t available in this build."
            } else {
                lastError = "Sign in with Apple failed: \(error.localizedDescription)"
            }
            Log.auth.error("Sign in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sets UserDefaults "auth.guestMode" = true, state = .guest.
    func continueWithoutSigningIn() {
        UserDefaults.standard.set(true, forKey: Keys.guestMode)
        lastError = nil
        state = .guest
    }

    /// Forgets the signed-in Apple user ID, clears the guest flag, state = .signedOut. The per-user name/email stay
    /// in Keychain (Apple only sends them on the very first authorization). Never deletes data.
    func signOut() {
        if let userID = keychain.string(for: Keys.userID), !userID.isEmpty {
            AuthService.migrateLegacyProfile(to: userID, keychain: keychain)
        }
        keychain.delete(Keys.userID)
        UserDefaults.standard.set(false, forKey: Keys.guestMode)
        displayName = nil
        email = nil
        state = .signedOut
        Log.auth.info("Signed out")
    }

    /// Moves the old unkeyed name/email items (which belonged to the signed-in user) to that user's keys.
    private static func migrateLegacyProfile(to userID: String, keychain: KeychainStore) {
        if let legacyName = keychain.string(for: Keys.legacyUserName) {
            if keychain.string(for: Keys.userName(userID)) == nil {
                keychain.set(legacyName, for: Keys.userName(userID))
            }
            keychain.delete(Keys.legacyUserName)
        }
        if let legacyEmail = keychain.string(for: Keys.legacyUserEmail) {
            if keychain.string(for: Keys.userEmail(userID)) == nil {
                keychain.set(legacyEmail, for: Keys.userEmail(userID))
            }
            keychain.delete(Keys.legacyUserEmail)
        }
    }
}
