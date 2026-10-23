import Foundation

/// A Trello action reduced to what a `TrelloActivity` stores, plus the board id for the board filter.
struct TrelloMappedAction: Equatable, Sendable {
    var actionID: String
    var occurredAt: Date
    var kind: TrelloActivityKind
    var cardName: String = ""
    var cardShortLink: String = ""
    var boardID: String = ""
    var boardName: String = ""
    var listName: String = ""
    var fromListName: String = ""
    var detail: String = ""
}

/// Pure mapping from Trello's action JSON (`GET /1/members/me/actions`) to `TrelloMappedAction`, and the pure rules
/// `TrelloService` applies before attaching actions to a session. No state, no I/O (unit-tested).
enum TrelloActionMapper {
    /// Longest `detail` stored (checklist item, comment excerpt, old card name), ellipsis included.
    static let detailLimit = 200

    /// The action types requested from Trello (`filter=`).
    static let actionTypes = [
        "createCard", "updateCard", "commentCard", "updateCheckItemStateOnCard", "deleteCard", "moveCardToBoard",
        "copyCard", "convertToCardFromCheckItem",
    ]

    /// One action dictionary → mapped fields, or nil when it isn't logged: unknown type, missing id/date, or an
    /// `updateCard` that only changed something else (position, due date, labels, cover…).
    ///
    /// updateCard (by `data.old` key, first match wins): idList → moved (listBefore → listAfter); closed →
    /// archived/unarchived; dueComplete → completed/reopened; name → renamed (detail = old name).
    static func map(_ action: [String: Any]) -> TrelloMappedAction? {
        let id = string(action["id"])
        guard !id.isEmpty, let type = action["type"] as? String,
              let dateString = action["date"] as? String, let date = parseDate(dateString) else { return nil }
        let data = dictionary(data: action["data"])
        let card = dictionary(data: data["card"])
        let board = dictionary(data: data["board"])
        let list = dictionary(data: data["list"])

        var result = TrelloMappedAction(actionID: id, occurredAt: date, kind: .other)
        result.cardName = string(card["name"])
        result.cardShortLink = string(card["shortLink"])
        result.boardID = string(board["id"])
        result.boardName = string(board["name"])
        result.listName = string(list["name"])

        switch type {
        case "createCard", "convertToCardFromCheckItem":
            result.kind = .created
        case "commentCard":
            result.kind = .commented
            result.detail = excerpt(string(data["text"]))
        case "updateCheckItemStateOnCard":
            let item = dictionary(data: data["checkItem"])
            result.kind = string(item["state"]) == "complete" ? .checkedItem : .uncheckedItem
            result.detail = excerpt(string(item["name"]))
        case "deleteCard":
            result.kind = .deleted
        case "moveCardToBoard":
            result.kind = .movedToBoard
        case "copyCard":
            result.kind = .copied
        case "updateCard":
            let old = dictionary(data: data["old"])
            if old["idList"] != nil {
                result.kind = .moved
                let after = string(dictionary(data: data["listAfter"])["name"])
                if !after.isEmpty { result.listName = after }
                result.fromListName = string(dictionary(data: data["listBefore"])["name"])
            } else if old["closed"] != nil {
                let closed = bool(card["closed"]) ?? !(bool(old["closed"]) ?? false)
                result.kind = closed ? .archived : .unarchived
            } else if old["dueComplete"] != nil {
                let complete = bool(card["dueComplete"]) ?? !(bool(old["dueComplete"]) ?? false)
                result.kind = complete ? .completed : .reopened
            } else if old["name"] != nil {
                result.kind = .renamed
                result.detail = excerpt(string(old["name"]))
            } else if old["desc"] != nil {
                result.kind = .editedDescription
                result.detail = excerpt(string(card["desc"]))
            } else {
                return nil
            }
        default:
            return nil
        }
        return result
    }

    /// The action dictionaries in `page` whose `idMemberCreator` is `memberID` (the user's own actions).
    static func madeBy(_ memberID: String, _ page: [Any]) -> [Any] {
        page.filter { element in
            guard let action = element as? [String: Any] else { return false }
            return string(action["idMemberCreator"]) == memberID
        }
    }

    /// Maps every dictionary of a decoded JSON array; non-dictionaries and unlogged actions are dropped.
    static func mapAll(_ json: Any) -> [TrelloMappedAction] {
        guard let array = json as? [Any] else { return [] }
        return array.compactMap { element in (element as? [String: Any]).flatMap { Self.map($0) } }
    }

    /// Board filter: empty `watched` = every board.
    static func isOnWatchedBoard(_ action: TrelloMappedAction, watched: Set<String>) -> Bool {
        watched.isEmpty || watched.contains(action.boardID)
    }

    /// The actions to attach to a session: dated within [start, end] (end nil = still running), on a watched board,
    /// not attached yet (`existingActionIDs`), each action once; oldest first.
    static func actionsToAttach(_ actions: [TrelloMappedAction], existingActionIDs: Set<String>,
                                watchedBoardIDs: Set<String>, start: Date, end: Date?) -> [TrelloMappedAction] {
        var seen = existingActionIDs
        var result: [TrelloMappedAction] = []
        for action in actions.sorted(by: { ($0.occurredAt, $0.actionID) < ($1.occurredAt, $1.actionID) }) {
            guard action.occurredAt >= start, end.map({ action.occurredAt <= $0 }) ?? true,
                  isOnWatchedBoard(action, watched: watchedBoardIDs),
                  seen.insert(action.actionID).inserted else { continue }
            result.append(action)
        }
        return result
    }

    /// Where the next fetch for a session starts (`since=`): the session's cursor (end of the last fully successful
    /// fetch window; nil = none yet) minus `overlap`, never before the session's start. The overlap catches actions
    /// that show up in Trello's API a little late or under a slightly different clock; actions already seen are
    /// skipped by action id (`TrelloService` also skips ids the previous fetch returned, so a removed entry isn't
    /// re-added).
    static func fetchStart(sessionStart: Date, cursor: Date?, overlap: TimeInterval = 60) -> Date {
        max(sessionStart, (cursor ?? sessionStart).addingTimeInterval(-overlap))
    }

    // MARK: - Dates

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    /// Trello dates ("2026-10-23T09:15:02.123Z"); also accepts no fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    /// ISO-8601 with milliseconds, UTC (for `since=` / `before=`).
    static func formatDate(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    // MARK: - Text

    /// One line (whitespace runs collapsed), at most `detailLimit` characters with "…" when cut.
    static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > detailLimit else { return line }
        return String(line.prefix(detailLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Private

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func dictionary(data value: Any?) -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }
}
