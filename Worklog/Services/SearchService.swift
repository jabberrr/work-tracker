import Foundation
import SwiftData

struct SearchSnippet: Equatable {
    enum Field: String { case title, label, tag, segmentFocus, note, learning, learningPoint, attachmentCaption }
    let field: Field
    let text: String      // ≤ 120 chars, centered on the first match, "…" added when truncated
}

/// In-memory, case- and diacritic-insensitive search over sessions and learning points.
enum SearchService {
    static let snippetLength = 120

    /// Lowercased, diacritic-folded, whitespace-split, empty removed. Quoted phrases ("deep work") are one term.
    static func terms(from query: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        func flush() {
            let term = fold(current.trimmed)
            if !term.isEmpty { result.append(term) }
            current = ""
        }

        for character in query {
            if character == "\"" || character == "“" || character == "”" || character == "„" {
                flush()
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    /// AND across terms; each term must match (case/diacritic-insensitive substring) at least one of: title, label name,
    /// session tags, segment labels/tags/focus, note texts, learningText, overlaySummary, learning point texts + tags,
    /// attachment captions/filenames.
    static func matches(_ session: WorkSession, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = searchableTexts(of: session).map(fold)
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// text, tags, session title
    static func matches(_ point: LearningPoint, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        var texts = [point.text]
        texts += point.tagList.map(\.name)
        if let title = point.session?.title { texts.append(title) }
        let haystack = texts.map(fold)
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// Empty query → input unchanged.
    static func filter(_ sessions: [WorkSession], query: String) -> [WorkSession] {
        let parsed = terms(from: query)
        guard !parsed.isEmpty else { return sessions }
        return sessions.filter { matches($0, terms: parsed) }
    }

    /// First match for the first term in field order (label, tag, segmentFocus, note, learning, learningPoint,
    /// attachmentCaption). The title has last priority: nil when only the title matched (rows already show it).
    static func snippet(for session: WorkSession, query: String) -> SearchSnippet? {
        guard let term = terms(from: query).first else { return nil }
        for (field, texts) in fieldTexts(of: session) {
            for text in texts {
                if let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
                    return SearchSnippet(field: field, text: excerpt(text, around: range))
                }
            }
        }
        return nil
    }

    // MARK: - Private

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    private static func searchableTexts(of session: WorkSession) -> [String] {
        [session.title] + fieldTexts(of: session).flatMap { $0.1 }
    }

    /// Snippet fields in priority order (title excluded).
    private static func fieldTexts(of session: WorkSession) -> [(SearchSnippet.Field, [String])] {
        let segments = session.sortedSegments
        let points = session.sortedLearningPoints
        let attachments = session.sortedAttachments
        return [
            (.label, [session.label?.name].compactMap { $0 } + segments.compactMap { $0.label?.name }),
            (.tag, session.tagList.map(\.name) + segments.flatMap { $0.tagList.map(\.name) }),
            (.segmentFocus, segments.map(\.focus).filter { !$0.isEmpty }),
            (.note, session.sortedNotes.map(\.text)),
            (.learning, [session.learningText, session.overlaySummary].filter { !$0.isEmpty }),
            (.learningPoint, points.map(\.text) + points.flatMap { $0.tagList.map(\.name) }),
            (.attachmentCaption, attachments.map(\.caption).filter { !$0.isEmpty } + attachments.map(\.filename)),
        ]
    }

    /// ≤ `snippetLength` characters (ellipses included), centered on `range`; newlines collapsed to spaces.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let total = text.count
        guard total > snippetLength else { return flatten(text) }

        let budget = snippetLength - 2 // room for a leading and trailing "…"
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
        var start = max(0, matchStart - max(0, budget - matchLength) / 2)
        start = min(start, max(0, total - budget))
        let end = min(total, start + budget)

        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        var result = flatten(String(text[lower..<upper])).trimmed
        if start > 0 { result = "…" + result }
        if end < total { result += "…" }
        return result
    }

    private static func flatten(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
