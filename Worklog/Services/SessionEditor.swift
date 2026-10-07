import Foundation
import SwiftData

enum SessionEditError: LocalizedError {
    case dateOutOfRange, segmentTooShort, noAdjacentSegment, lastSegment, sessionIsActive

    var errorDescription: String? {
        switch self {
        case .dateOutOfRange:
            "That time is outside the allowed range."
        case .segmentTooShort:
            "Segments must be at least \(Int(SessionEditor.minimumSegmentLength)) second long."
        case .noAdjacentSegment:
            "There is no following segment to merge with."
        case .lastSegment:
            "A session needs at least one segment."
        case .sessionIsActive:
            "This session is still running. Stop it first."
        }
    }
}

/// After-the-fact edits to sessions (used by History/Detail; the engine reuses `normalize` and `endSession`).
/// Every mutating call touches the session, recomputes its stored duration, normalizes it and saves.
@MainActor enum SessionEditor {
    nonisolated static let minimumSegmentLength: TimeInterval = 1

    // MARK: - Segments

    /// Split `segment` at `date` (must be > start+min and < end−min, else .dateOutOfRange/.segmentTooShort).
    /// Original keeps [start, date); new segment gets [date, end) with `label` (nil → original's label),
    /// `tags` (nil → copy original's tags), `focus`. Notes with createdAt >= date move to the new segment.
    @discardableResult
    static func split(_ segment: Segment, at date: Date, label: WorkLabel?, tags: [WorkTag]?, focus: String,
                      in context: ModelContext) throws -> Segment {
        guard let session = segment.session else { throw SessionEditError.dateOutOfRange }
        let start = segment.startedAt
        let end = segment.endedAt ?? session.endedAt ?? .now
        guard date > start, date < end else { throw SessionEditError.dateOutOfRange }
        guard date.timeIntervalSince(start) >= minimumSegmentLength,
              end.timeIntervalSince(date) >= minimumSegmentLength else { throw SessionEditError.segmentTooShort }

        let newSegment = Segment(startedAt: date, endedAt: segment.endedAt,
                                 sortIndex: segment.sortIndex + 1, focus: focus.trimmed)
        context.insert(newSegment)
        newSegment.label = label ?? segment.label
        newSegment.tags = tags ?? segment.tagList
        newSegment.session = session
        segment.endedAt = date

        let moving = segment.sortedNotes.filter { $0.createdAt >= date }
        for note in moving { note.segment = newSegment }

        // Later segments need room for the new index; normalize renumbers by start time.
        finish(session, in: context)
        return newSegment
    }

    /// Absorb the next segment into `segment` (next deleted, its notes reassigned). Throws .noAdjacentSegment.
    static func mergeWithNext(_ segment: Segment, in context: ModelContext) throws {
        guard let session = segment.session else { throw SessionEditError.noAdjacentSegment }
        let segments = liveSegments(of: session)
        guard let index = segments.firstIndex(where: { $0 === segment }), index + 1 < segments.count else {
            throw SessionEditError.noAdjacentSegment
        }
        let next = segments[index + 1]
        segment.endedAt = next.endedAt
        for note in next.sortedNotes { note.segment = segment }
        remove(next, in: context)
        finish(session, in: context)
    }

    /// Delete segment; its time goes to previous (or next if first); notes reassigned. Throws .lastSegment.
    static func deleteSegment(_ segment: Segment, in context: ModelContext) throws {
        guard let session = segment.session else {
            context.delete(segment)
            save(context)
            return
        }
        let segments = liveSegments(of: session)
        guard segments.count > 1, let index = segments.firstIndex(where: { $0 === segment }) else {
            throw SessionEditError.lastSegment
        }
        let receiver: Segment
        if index > 0 {
            receiver = segments[index - 1]
            receiver.endedAt = segment.endedAt
        } else {
            receiver = segments[1]
            receiver.startedAt = segment.startedAt
        }
        for note in segment.sortedNotes { note.segment = receiver }
        remove(segment, in: context)
        finish(session, in: context)
    }

    /// Move the boundary between `segment` and its successor to `date` (respecting minimumSegmentLength).
    static func moveBoundary(after segment: Segment, to date: Date, in context: ModelContext) throws {
        guard let session = segment.session else { throw SessionEditError.noAdjacentSegment }
        let segments = liveSegments(of: session)
        guard let index = segments.firstIndex(where: { $0 === segment }), index + 1 < segments.count else {
            throw SessionEditError.noAdjacentSegment
        }
        let next = segments[index + 1]
        let lowerBound = segment.startedAt
        let upperBound = next.endedAt ?? session.endedAt ?? .now
        guard date > lowerBound, date < upperBound else { throw SessionEditError.dateOutOfRange }
        guard date.timeIntervalSince(lowerBound) >= minimumSegmentLength,
              upperBound.timeIntervalSince(date) >= minimumSegmentLength else { throw SessionEditError.segmentTooShort }

        segment.endedAt = date
        next.startedAt = date
        reassignNotesByTime(session)
        finish(session, in: context)
    }

    // MARK: - Session times & label

    /// Ended sessions only (.sessionIsActive otherwise). start < end required. First segment start / last segment end
    /// follow; segments fully outside are clamped to min length; pauses are clipped to [start, end].
    static func setTimes(of session: WorkSession, start: Date, end: Date, in context: ModelContext) throws {
        guard session.endedAt != nil else { throw SessionEditError.sessionIsActive }
        guard start < end else { throw SessionEditError.dateOutOfRange }

        session.startedAt = start
        session.endedAt = end

        // Re-place interior segment starts so every segment stays ≥ minimumSegmentLength when possible.
        let segments = liveSegments(of: session).sorted { ($0.startedAt, $0.sortIndex) < ($1.startedAt, $1.sortIndex) }
        let count = segments.count
        if count > 0 {
            let total = end.timeIntervalSince(start)
            let feasible = total >= Double(count) * minimumSegmentLength
            var previousStart = start
            for (i, seg) in segments.enumerated() {
                let newStart: Date
                if i == 0 {
                    newStart = start
                } else if feasible {
                    let lower = previousStart.addingTimeInterval(minimumSegmentLength)
                    let upper = end.addingTimeInterval(-Double(count - i) * minimumSegmentLength)
                    newStart = min(max(seg.startedAt, lower), upper)
                } else {
                    newStart = start.addingTimeInterval(total * Double(i) / Double(count))
                }
                if seg.startedAt != newStart { seg.startedAt = newStart }
                previousStart = newStart
            }
        }

        session.pauseIntervals = clippedPauses(session.pauseIntervals, start: start, end: end)
        normalize(session)
        reassignNotesByTime(session)
        finish(session, in: context)
    }

    /// Set session.label; every segment whose label was the OLD primary label (or nil) is updated to the new one.
    static func setPrimaryLabel(_ label: WorkLabel?, for session: WorkSession, in context: ModelContext) {
        let old = session.label
        for seg in liveSegments(of: session) {
            if seg.label == nil || (old != nil && seg.label === old) {
                seg.label = label
            }
        }
        session.label = label
        finish(session, in: context)
    }

    // MARK: - Invariants

    /// Re-number sortIndex by startedAt, enforce contiguity, ensure ≥1 segment (creates one if missing).
    static func normalize(_ session: WorkSession) {
        var segments = liveSegments(of: session)
            .sorted { ($0.startedAt, $0.sortIndex) < ($1.startedAt, $1.sortIndex) }

        if segments.isEmpty {
            guard let context = session.modelContext else { return }
            let seg = Segment(startedAt: session.startedAt, endedAt: session.endedAt, sortIndex: 0)
            context.insert(seg)
            seg.label = session.label
            seg.session = session
            segments = [seg]
        }

        let sessionStart = session.startedAt
        let sessionEnd = session.endedAt
        var previousStart = sessionStart
        for (i, seg) in segments.enumerated() {
            var start = (i == 0) ? sessionStart : max(seg.startedAt, previousStart)
            if let sessionEnd { start = min(start, max(sessionEnd, sessionStart)) }
            if seg.startedAt != start { seg.startedAt = start }
            if seg.sortIndex != i { seg.sortIndex = i }
            previousStart = start
        }
        for i in segments.indices {
            let end: Date? = (i + 1 < segments.count) ? segments[i + 1].startedAt : sessionEnd
            if segments[i].endedAt != end { segments[i].endedAt = end }
        }
    }

    /// Ends `session` at `date` (clamped to ≥ its last segment start and ≥ startedAt): closes an open pause at the
    /// end, drops/clips pauses after it, sets the last segment's and the session's `endedAt`, normalizes and
    /// recomputes the stored duration. Does NOT save. Shared by the engine (stop) and SeedData (extra actives).
    static func endSession(_ session: WorkSession, at date: Date) {
        let segments = liveSegments(of: session)
        let lastStart = segments.map(\.startedAt).max() ?? session.startedAt
        let end = max(date, lastStart, session.startedAt)
        session.pauseIntervals = clippedPauses(session.pauseIntervals, start: session.startedAt, end: end)
        session.endedAt = end
        normalize(session)
        session.recomputeStoredDuration(now: end)
        session.touch()
    }

    // MARK: - Sessions

    /// Throws .sessionIsActive for the active session (use engine.discard()).
    static func deleteSession(_ session: WorkSession, in context: ModelContext) throws {
        guard session.endedAt != nil else { throw SessionEditError.sessionIsActive }
        context.delete(session)
        save(context)
    }

    // MARK: - Notes

    /// Note in any session at `date`; segment = session.segment(containing: date).
    @discardableResult
    static func addNote(_ text: String, at date: Date, to session: WorkSession, in context: ModelContext) -> Note {
        let note = Note(text: text.trimmed, createdAt: date)
        context.insert(note)
        note.session = session
        note.segment = session.segment(containing: date)
        finish(session, in: context)
        return note
    }

    /// Sets text, editedAt = now; createdAt changed only if `date` given (segment reassigned).
    static func updateNote(_ note: Note, text: String, date: Date?, in context: ModelContext) {
        note.text = text
        note.editedAt = .now
        if let date {
            note.createdAt = date
            note.segment = note.session?.segment(containing: date)
        }
        if let session = note.session {
            finish(session, in: context)
        } else {
            save(context)
        }
    }

    static func deleteNote(_ note: Note, in context: ModelContext) {
        let session = note.session
        note.segment = nil
        note.session = nil
        context.delete(note)
        if let session { finish(session, in: context) } else { save(context) }
    }

    static func deleteAttachment(_ attachment: Attachment, in context: ModelContext) {
        let session = attachment.session
        attachment.session = nil
        context.delete(attachment)
        if let session { finish(session, in: context) } else { save(context) }
    }

    // MARK: - Learning points

    /// sortIndex = max+1.
    @discardableResult
    static func addLearningPoint(_ text: String, tags: [WorkTag], to session: WorkSession,
                                 in context: ModelContext) -> LearningPoint {
        let nextIndex = ((session.learningPoints ?? []).map(\.sortIndex).max() ?? -1) + 1
        let point = LearningPoint(text: text.trimmed, createdAt: .now, sortIndex: nextIndex)
        context.insert(point)
        point.tags = tags
        point.session = session
        finish(session, in: context)
        return point
    }

    static func deleteLearningPoint(_ point: LearningPoint, in context: ModelContext) {
        let session = point.session
        point.session = nil
        context.delete(point)
        if let session { finish(session, in: context) } else { save(context) }
    }

    /// Assign sortIndex by array order.
    static func reorderLearningPoints(_ points: [LearningPoint]) {
        for (index, point) in points.enumerated() where point.sortIndex != index {
            point.sortIndex = index
        }
        if let session = points.first?.session {
            session.touch()
        }
        if let context = points.first?.modelContext {
            save(context)
        }
    }

    // MARK: - Private helpers

    /// touch + normalize + recomputeStoredDuration + save.
    private static func finish(_ session: WorkSession, in context: ModelContext) {
        normalize(session)
        session.recomputeStoredDuration()
        session.touch()
        save(context)
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            Log.persistence.error("SessionEditor save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Segments of `session` that aren't pending deletion, sorted by sortIndex/start.
    private static func liveSegments(of session: WorkSession) -> [Segment] {
        session.sortedSegments.filter { !$0.isDeleted }
    }

    /// Detach then delete, so relationship arrays don't keep the deleted object until the next save.
    private static func remove(_ segment: Segment, in context: ModelContext) {
        segment.session = nil
        context.delete(segment)
    }

    /// Every note of the session goes to the segment containing its timestamp.
    private static func reassignNotesByTime(_ session: WorkSession) {
        for note in session.notes ?? [] where !note.isDeleted {
            let target = session.segment(containing: note.createdAt)
            if note.segment !== target { note.segment = target }
        }
    }

    /// Pauses clipped to [start, end]; open pauses are closed at `end`; empty ones dropped.
    private static func clippedPauses(_ pauses: [PauseInterval], start: Date, end: Date) -> [PauseInterval] {
        pauses.compactMap { pause in
            let s = max(pause.start, start)
            let e = min(pause.end ?? end, end)
            guard e > s else { return nil }
            return PauseInterval(start: s, end: e)
        }
    }
}
