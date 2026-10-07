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
    /// Apple only returns name/email on first sign-in → stored in Keychain.
    private(set) var displayName: String? = nil
    private(set) var email: String? = nil
    var lastError: String? = nil

    /// state is .signedIn
    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// state == .signedOut
    var needsWelcome: Bool { state == .signedOut }

    private enum Keys {
        static let userID = "appleUserID"
        static let userName = "appleUserName"
        static let userEmail = "appleUserEmail"
        static let guestMode = "auth.guestMode"
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
            state = .signedIn(userID: userID)
            displayName = keychain.string(for: Keys.userName)
            email = keychain.string(for: Keys.userEmail)
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
                lastError = "Unexpected sign-in credential. Please try again."
                return
            }
            let userID = credential.user
            let previousUserID = keychain.string(for: Keys.userID)
            if previousUserID != userID {
                // A different Apple ID: forget the previous person's name/email.
                keychain.delete(Keys.userName)
                keychain.delete(Keys.userEmail)
                displayName = nil
                email = nil
            }
            keychain.set(userID, for: Keys.userID)

            if let nameComponents = credential.fullName {
                let formatted = PersonNameComponentsFormatter.localizedString(from: nameComponents, style: .default)
                if let name = formatted.nilIfBlank {
                    keychain.set(name, for: Keys.userName)
                    displayName = name
                }
            }
            if let mail = credential.email?.nilIfBlank {
                keychain.set(mail, for: Keys.userEmail)
                email = mail
            }
            if displayName == nil { displayName = keychain.string(for: Keys.userName) }
            if email == nil { email = keychain.string(for: Keys.userEmail) }

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
                lastError = "Sign in with Apple isn't configured for this build — continue without signing in."
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

    /// Deletes Keychain items, clears guest flag, state = .signedOut. Never deletes data.
    func signOut() {
        keychain.delete(Keys.userID)
        keychain.delete(Keys.userName)
        keychain.delete(Keys.userEmail)
        UserDefaults.standard.set(false, forKey: Keys.guestMode)
        displayName = nil
        email = nil
        state = .signedOut
        Log.auth.info("Signed out")
    }
}
