import Foundation
import SwiftData

/// One Trello card action of the user, logged while a session ran on this Mac (`TrelloService`). Additive model:
/// every attribute has a default and the session relationship is optional (CloudKit). Text fields are encrypted in
/// iCloud. Deleted with its session (cascade).
@Model
final class TrelloActivity {
    var uuid: UUID = UUID()
    /// Trello action id: a session never gets the same action twice.
    var actionID: String = ""
    /// The action's Trello timestamp.
    var occurredAt: Date = Date()
    /// `TrelloActivityKind` raw value. Use `kind`.
    var kindRaw: String = "other"
    @Attribute(.allowsCloudEncryption) var cardName: String = ""
    /// Card short link (https://trello.com/c/<shortLink>); "" when Trello didn't send one.
    var cardShortLink: String = ""
    @Attribute(.allowsCloudEncryption) var boardName: String = ""
    /// The list after the action (or the card's list).
    @Attribute(.allowsCloudEncryption) var listName: String = ""
    /// Moves only: the list the card came from.
    @Attribute(.allowsCloudEncryption) var fromListName: String = ""
    /// Checklist item, comment excerpt or (renames) the old card name; ≤ 200 characters.
    @Attribute(.allowsCloudEncryption) var detail: String = ""
    var session: WorkSession?

    init(actionID: String, occurredAt: Date, kind: TrelloActivityKind, uuid: UUID = UUID()) {
        self.uuid = uuid
        self.actionID = actionID
        self.occurredAt = occurredAt
        self.kindRaw = kind.rawValue
    }
}

enum TrelloActivityKind: String, CaseIterable, Codable {
    case created, moved, completed, reopened, archived, unarchived, commented, checkedItem, uncheckedItem,
         renamed, editedDescription, deleted, movedToBoard, copied, other
}

extension TrelloActivity {
    /// Unknown raw values (a newer app version) read as `.other`.
    var kind: TrelloActivityKind {
        get { TrelloActivityKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// One line, e.g. Moved “Fix login” from Doing to Done.
    var summary: String {
        TrelloActivity.summary(kind: kind, cardName: cardName, listName: listName, fromListName: fromListName,
                               detail: detail)
    }

    /// https://trello.com/c/<shortLink>; nil when there is no short link.
    var cardURL: URL? {
        TrelloActivity.cardURL(shortLink: cardShortLink)
    }

    /// SF Symbol for the kind.
    var systemImage: String { kind.systemImage }

    /// Pure: the summary line for the given fields (unit-tested).
    static func summary(kind: TrelloActivityKind, cardName: String, listName: String, fromListName: String,
                        detail: String) -> String {
        let card = quoted(cardName)
        let list = listName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromList = fromListName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .created:
            return list.isEmpty ? "Added \(card)" : "Added \(card) to \(list)"
        case .moved:
            if fromList.isEmpty { return list.isEmpty ? "Moved \(card)" : "Moved \(card) to \(list)" }
            return list.isEmpty ? "Moved \(card) from \(fromList)" : "Moved \(card) from \(fromList) to \(list)"
        case .completed:
            return "Completed \(card)"
        case .reopened:
            return "Reopened \(card)"
        case .archived:
            return "Archived \(card)"
        case .unarchived:
            return "Restored \(card)"
        case .commented:
            return "Commented on \(card)"
        case .checkedItem:
            return "Checked \(quoted(detail, fallback: "an item")) on \(card)"
        case .uncheckedItem:
            return "Unchecked \(quoted(detail, fallback: "an item")) on \(card)"
        case .renamed:
            let old = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return old.isEmpty ? "Renamed a card to \(card)" : "Renamed \(quoted(old)) to \(card)"
        case .editedDescription:
            return detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Cleared the description of \(card)" : "Edited the description of \(card)"
        case .deleted:
            let what = cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a card" : card
            return list.isEmpty ? "Deleted \(what)" : "Deleted \(what) from \(list)"
        case .movedToBoard:
            return "Moved \(card) to another board"
        case .copied:
            return "Copied \(card)"
        case .other:
            return "Updated \(card)"
        }
    }

    static func cardURL(shortLink: String) -> URL? {
        let link = shortLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty,
              link.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return URL(string: "https://trello.com/c/\(link)")
    }

    /// “text” (curly quotes), or `fallback` unquoted when blank.
    private static func quoted(_ text: String, fallback: String = "a card") -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : "\u{201C}\(trimmed)\u{201D}"
    }
}

extension TrelloActivityKind {
    var systemImage: String {
        switch self {
        case .created: "plus.rectangle"
        case .moved: "arrow.right"
        case .completed: "checkmark.circle"
        case .reopened: "arrow.uturn.backward"
        case .archived: "archivebox"
        case .unarchived: "tray.and.arrow.up"
        case .commented: "text.bubble"
        case .checkedItem: "checklist"
        case .uncheckedItem: "checklist.unchecked"
        case .renamed: "pencil"
        case .editedDescription: "text.alignleft"
        case .deleted: "trash"
        case .movedToBoard: "rectangle.portrait.and.arrow.right"
        case .copied: "doc.on.doc"
        case .other: "square.and.pencil"
        }
    }
}
