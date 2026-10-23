import Foundation

/// Why a Trello request failed.
enum TrelloAPIError: Error, Equatable {
    /// 401: the token was revoked or expired (or the API key is invalid).
    case unauthorized
    /// 429.
    case rateLimited
    /// 5xx.
    case server(Int)
    /// Any other non-2xx status.
    case http(Int)
    /// No connection, timeout, DNS… (URLError).
    case offline
    /// Not the JSON shape we expect.
    case invalidResponse

    /// Short user-facing text (`TrelloService.lastError`).
    var userMessage: String {
        switch self {
        case .unauthorized: "Trello disconnected. Connect again."
        case .rateLimited: "Trello is busy. Trying again in a minute."
        case .server, .http: "Trello isn\u{2019}t responding. Trying again in a minute."
        case .offline: "Can\u{2019}t reach Trello. Trying again in a minute."
        case .invalidResponse: "Trello sent an unexpected reply. Trying again in a minute."
        }
    }
}

/// Trello REST calls (https://api.trello.com/1) with the public API key and the user's token, straight from this Mac.
/// URLSession async, 20 s timeout, JSON parsed with JSONSerialization off the main actor. URLs carry the token, so
/// they are never logged.
struct TrelloAPI: Sendable {
    let key: String
    let token: String

    static let baseURL = URL(string: "https://api.trello.com/1")!
    static let timeout: TimeInterval = 20
    /// Trello's maximum page size for actions.
    static let pageLimit = 1000
    /// Safety cap: at most this many pages per fetch.
    static let maxPages = 10

    /// `GET /members/me?fields=fullName,username` → full name, else username.
    func memberName() async throws -> String {
        let json = try await send("members/me", query: [("fields", "fullName,username")])
        guard let member = json as? [String: Any] else { throw TrelloAPIError.invalidResponse }
        let fullName = ((member["fullName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty { return fullName }
        let username = ((member["username"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "Trello" : username
    }

    /// `GET /members/me?fields=id` → the member's id.
    func memberID() async throws -> String {
        let json = try await send("members/me", query: [("fields", "id")])
        guard let member = json as? [String: Any], let id = member["id"] as? String, !id.isEmpty else {
            throw TrelloAPIError.invalidResponse
        }
        return id
    }

    /// `GET /members/me/boards?filter=open&fields=name`, sorted by name.
    func boards() async throws -> [TrelloBoard] {
        let json = try await send("members/me/boards", query: [("filter", "open"), ("fields", "name")])
        guard let array = json as? [Any] else { throw TrelloAPIError.invalidResponse }
        let boards: [TrelloBoard] = array.compactMap { element in
            guard let board = element as? [String: Any], let id = board["id"] as? String, !id.isEmpty else { return nil }
            return TrelloBoard(id: id, name: (board["name"] as? String) ?? "")
        }
        return TrelloService.sortedBoards(boards)
    }

    /// The user's own card actions (`GET /members/me/actions`) dated after `since` (and before `before`), mapped;
    /// unlogged ones are dropped. Pages of `pageLimit` (newest first) continue with `before=<oldest action id>`.
    func actions(since: Date, before: Date?) async throws -> [TrelloMappedAction] {
        // members/me/actions also lists other people's actions that involve this member (a card they're on), so
        // only actions this member made are kept (`idMemberCreator`).
        let memberID = try await memberID()
        var cursor: String? = before.map(TrelloActionMapper.formatDate)
        var result: [TrelloMappedAction] = []
        for _ in 0..<Self.maxPages {
            var query: [(String, String)] = [
                ("filter", TrelloActionMapper.actionTypes.joined(separator: ",")),
                ("since", TrelloActionMapper.formatDate(since)),
                ("limit", String(Self.pageLimit)),
            ]
            if let cursor { query.append(("before", cursor)) }
            let json = try await send("members/me/actions", query: query)
            guard let page = json as? [Any] else { throw TrelloAPIError.invalidResponse }
            result += TrelloActionMapper.mapAll(TrelloActionMapper.madeBy(memberID, page))
            guard page.count >= Self.pageLimit, let oldest = page.last as? [String: Any],
                  let oldestID = oldest["id"] as? String, !oldestID.isEmpty, oldestID != cursor else { break }
            cursor = oldestID
        }
        return result
    }

    /// Best effort `DELETE /tokens/{token}` (Disconnect). Errors are ignored.
    func revokeToken() async {
        _ = try? await send("tokens/\(token)", method: "DELETE", query: [])
    }

    // MARK: - URLs (pure)

    /// https://trello.com/1/authorize?expiration=never&name=Diptychon&scope=read&response_type=token&key=KEY
    /// (+ &callback_method=fragment&return_url=diptychon-trello://auth when `withCallback`). nil without a key.
    static func authorizeURL(key: String, withCallback: Bool) -> URL? {
        guard !key.isEmpty else { return nil }
        var items: [(String, String)] = [
            ("expiration", "never"), ("name", TrelloConfig.appName), ("scope", "read"),
            ("response_type", "token"), ("key", key),
        ]
        if withCallback {
            items.append(("callback_method", "fragment"))
            items.append(("return_url", "\(TrelloConfig.callbackScheme)://auth"))
        }
        var components = URLComponents(string: "https://trello.com/1/authorize")
        components?.percentEncodedQuery = encodedQuery(items)
        return components?.url
    }

    /// The token from the web-auth callback (diptychon-trello://auth#token=…); nil when it has none.
    static func token(fromCallback url: URL) -> String? {
        guard url.scheme?.lowercased() == TrelloConfig.callbackScheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = [components?.fragment, components?.query].compactMap { $0 }.joined(separator: "&")
        for part in parts.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "token" { return normalizedToken(String(pair[1])) }
        }
        return nil
    }

    /// A pasted token (or a pasted "…token=<token>" URL), trimmed; nil when it can't be a token.
    static func normalizedToken(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "token=") {
            value = String(value[range.upperBound...].prefix { $0 != "&" })
        }
        let allowed = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard !value.isEmpty, value.count <= 512, allowed else { return nil }
        return value
    }

    // MARK: - Private

    /// Sends the request and decodes the JSON body (`NSNull` for an empty body).
    private func send(_ path: String, method: String = "GET", query: [(String, String)]) async throws -> Any {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = Self.encodedQuery(query + [("key", key), ("token", token)])
        guard let url = components?.url else { throw TrelloAPIError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw TrelloAPIError.offline
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw TrelloAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw TrelloAPIError.unauthorized
        case 429: throw TrelloAPIError.rateLimited
        case 500..<600: throw TrelloAPIError.server(http.statusCode)
        default: throw TrelloAPIError.http(http.statusCode)
        }
        guard !data.isEmpty else { return NSNull() }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw TrelloAPIError.invalidResponse
        }
    }

    /// RFC 3986 unreserved characters only, so values (dates, the return URL) are always encoded the same way.
    private static func encodedQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
