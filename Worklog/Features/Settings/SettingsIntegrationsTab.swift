import AppKit
import SwiftUI

/// Integrations: Trello. Connect (browser sign-in, or paste a token from Trello's authorize page), then choose whether
/// card activity is logged during sessions and from which boards; Disconnect (confirmed) revokes and forgets the
/// token. Logged entries stay with their sessions. Everything goes through `TrelloService`.
@MainActor
struct SettingsIntegrationsTab: View {
    @Environment(TrelloService.self) private var trello
    @Environment(\.theme) private var theme

    @State private var showsTokenEntry = false
    @State private var pastedToken = ""
    @State private var tokenRejected = false
    @State private var choosesBoards = false
    @State private var confirmsDisconnect = false

    var body: some View {
        Form {
            Section("Trello") {
                trelloContent
            }
        }
        .formStyle(.grouped)
        .onAppear { choosesBoards = !trello.watchedBoardIDs.isEmpty }
        .task(id: trello.isConnected) {
            if trello.isConnected && trello.boards.isEmpty {
                await trello.refreshBoards()
            }
        }
        .confirmationDialog("Disconnect Trello?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await trello.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logged activity stays with your sessions.")
        }
    }

    @ViewBuilder
    private var trelloContent: some View {
        if !trello.isConfigured {
            SettingsFootnote("Trello isn’t set up in this build.")
        } else {
            switch trello.connection {
            case .notConfigured:
                SettingsFootnote("Trello isn’t set up in this build.")
            case .connected(let name):
                connectedContent(name: name)
            case .disconnected, .connecting, .failed:
                connectContent
            }
        }
    }

    private static let footnote = "Only your own card activity is logged, while a session runs on this Mac."

    // MARK: Connect

    private var isConnecting: Bool { trello.connection == .connecting }

    private var failureMessage: String? {
        if case .failed(let message) = trello.connection { return message }
        return nil
    }

    @ViewBuilder
    private var connectContent: some View {
        if let failureMessage {
            InlineBanner(failureMessage, style: .error)
        }
        HStack(spacing: theme.spacingS) {
            Button("Connect Trello…") {
                tokenRejected = false
                Task { await trello.connect() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isConnecting)
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            }
            Spacer(minLength: 0)
        }
        DisclosureGroup("Paste a token instead", isExpanded: $showsTokenEntry) {
            tokenEntry
                .padding(.top, theme.spacingXS)
        }
        SettingsFootnote(Self.footnote)
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            SettingsFootnote("Open Trello, allow access, then paste the token it shows.")
            HStack(spacing: theme.spacingS) {
                Button("Open Trello") {
                    if let url = trello.manualAuthorizeURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(trello.manualAuthorizeURL == nil)
                .fixedSize()
                SecureField("Token", text: $pastedToken, prompt: Text("Token"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(connectWithToken)
                    .accessibilityLabel("Token")
                Button("Connect", action: connectWithToken)
                    .buttonStyle(QuietButtonStyle())
                    .disabled(pastedToken.isBlank || isConnecting)
                    .fixedSize()
            }
            if tokenRejected && failureMessage == nil {
                Text("That token didn’t work.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private func connectWithToken() {
        let token = pastedToken.trimmed
        guard !token.isEmpty, !isConnecting else { return }
        tokenRejected = false
        Task {
            let connected = await trello.connect(pastedToken: token)
            if connected {
                pastedToken = ""
                showsTokenEntry = false
            } else {
                tokenRejected = true
            }
        }
    }

    // MARK: Connected

    @ViewBuilder
    private func connectedContent(name: String) -> some View {
        connectedRow(name: name)
        if let error = trello.lastError {
            InlineBanner(error, style: .warning)
        }
        Toggle("Log Trello activity during sessions", isOn: loggingBinding)
        ValuePicker("Log activity from", selection: boardScopeBinding, options: [false, true],
                    title: { $0 ? "chosen boards" : "all boards" })
            .disabled(!trello.isLoggingEnabled)
        if choosesBoards {
            boardList
                .disabled(!trello.isLoggingEnabled)
        }
        HStack {
            Spacer()
            Button("Disconnect…") { confirmsDisconnect = true }
                .buttonStyle(QuietButtonStyle())
        }
        SettingsFootnote(Self.footnote)
    }

    private func connectedRow(name: String) -> some View {
        HStack(spacing: theme.spacingM) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20 * theme.textScale))
                .foregroundStyle(theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isBlank ? "Connected to Trello" : "Connected as \(name)")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.textPrimary)
                Text("Read-only access. Diptychon never changes your boards.")
                    .font(theme.captionFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var loggingBinding: Binding<Bool> {
        Binding(get: { trello.isLoggingEnabled }, set: { trello.isLoggingEnabled = $0 })
    }

    /// false = all boards (no chosen IDs), true = only the boards checked below. Going back to all boards clears them.
    private var boardScopeBinding: Binding<Bool> {
        Binding(get: { choosesBoards }, set: { newValue in
            choosesBoards = newValue
            if !newValue { trello.watchedBoardIDs = [] }
        })
    }

    private func boardBinding(_ board: TrelloBoard) -> Binding<Bool> {
        Binding(get: { trello.watchedBoardIDs.contains(board.id) }, set: { isOn in
            if isOn {
                trello.watchedBoardIDs.insert(board.id)
            } else {
                trello.watchedBoardIDs.remove(board.id)
            }
        })
    }

    private var boardList: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(spacing: theme.spacingS) {
                Text("Boards")
                    .font(theme.calloutFont.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                if trello.isLoadingBoards {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading boards")
                }
                Spacer()
                Button {
                    Task { await trello.refreshBoards() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .disabled(trello.isLoadingBoards)
                .accessibilityLabel("Refresh boards")
                .help("Refresh")
            }
            if trello.boards.isEmpty {
                if !trello.isLoadingBoards {
                    SettingsFootnote("No open boards.")
                }
            } else {
                ForEach(trello.boards) { board in
                    Toggle(board.name, isOn: boardBinding(board))
                        .toggleStyle(.checkbox)
                }
            }
            if trello.watchedBoardIDs.isEmpty {
                SettingsFootnote("With none chosen, all boards are logged.")
            }
        }
    }
}
