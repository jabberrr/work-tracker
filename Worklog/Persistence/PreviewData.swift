import Foundation
import SwiftData

/// Sample content for SwiftUI previews (and `AppServices(inMemory: true)`).
@MainActor enum PreviewData {
    /// Seeds labels/tags, two profiles ("Work" with the default uuid and default label "Deep work"; "Personal" with a
    /// local label "Errands" and a local tag "family") + 12 ended sessions over the past 3 weeks (9 Work, 3 Personal;
    /// multi-segment, notes, learning points with tags, one session with showInOverlay + overlaySummary) and NO
    /// active session.
    static func populate(_ context: ModelContext) {
        SeedData.insertDefaults(into: context)

        let globalLabels = ((try? context.fetch(FetchDescriptor<WorkLabel>(sortBy: [SortDescriptor(\WorkLabel.sortIndex)]))) ?? [])
        let tags = ((try? context.fetch(FetchDescriptor<WorkTag>(sortBy: [SortDescriptor(\WorkTag.name)]))) ?? [])
        guard !globalLabels.isEmpty else { return }

        // Profiles: "Work" (fixed default uuid) and "Personal".
        let work = ProfileOps.profile(withID: ProfileOps.defaultProfileUUID, in: context)
            ?? WorkProfile(name: ProfileOps.defaultProfileName, colorHex: ProfileOps.defaultProfileColorHex,
                           symbolName: ProfileOps.defaultProfileSymbol, sortIndex: 0,
                           uuid: ProfileOps.defaultProfileUUID)
        if work.modelContext == nil { context.insert(work) }
        work.defaultLabelUUID = globalLabels.first { $0.name == "Deep work" }?.uuid
        let personal = WorkProfile(name: "Personal", colorHex: "#27AE60", symbolName: "house.fill", sortIndex: 1)
        context.insert(personal)

        // Personal-local label and tag.
        let errands = WorkLabel(name: "Errands", colorHex: "#F2C94C", symbolName: "cart.fill",
                                sortIndex: (globalLabels.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(errands)
        errands.profile = personal
        let familyTag = WorkTag(name: "family", colorHex: "#EB5757")
        context.insert(familyTag)
        familyTag.profile = personal

        let labels = globalLabels + [errands]
        func label(_ name: String) -> WorkLabel? { labels.first { $0.name == name } ?? labels.first }

        // A sub-label tag scoped to "Deep work".
        let swiftUITag = WorkTag(name: "swiftui", colorHex: "#F2994A")
        context.insert(swiftUITag)
        swiftUITag.label = label("Deep work")
        let allTags = tags + [swiftUITag, familyTag]
        func anyTag(_ name: String) -> WorkTag? { allTags.first { $0.name == name } }

        struct Blueprint {
            var daysAgo: Int
            var hour: Int
            var title: String
            var label: String
            var tags: [String]
            /// (focus, minutes, label override)
            var segments: [(String, Int, String?)]
            var pauseAfterMinutes: Int?
            var pauseMinutes: Int
            var notes: [(Int, String)]
            var learning: String
            var points: [(String, [String], Int)]
            /// In the "Personal" profile (else "Work").
            var personal = false
        }

        let blueprints: [Blueprint] = [
            Blueprint(daysAgo: 1, hour: 9, title: "Overlay polish", label: "Deep work", tags: ["coding", "swiftui"],
                      segments: [("Panel sizing", 50, nil), ("Opacity slider", 40, nil), ("Code review", 25, "Admin & email")],
                      pauseAfterMinutes: 45, pauseMinutes: 10,
                      notes: [(5, "NSPanel needs .nonactivatingPanel at init time."), (70, "Slider snaps at 5% steps.")],
                      learning: "Non-activating panels must opt in to becoming key for text input.",
                      points: [("canBecomeKey override lets TextFields work in a non-activating panel", ["coding", "swiftui"], 4)]),
            Blueprint(daysAgo: 2, hour: 10, title: "Weekly planning", label: "Planning", tags: ["writing"],
                      segments: [("Review last week", 20, nil), ("Plan next week", 35, nil)],
                      pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [(10, "Too many meetings on Tuesday.")],
                      learning: "Block focus time before accepting invites.",
                      points: [("Protect mornings for deep work", ["writing"], 3)]),
            Blueprint(daysAgo: 3, hour: 14, title: "Team sync", label: "Meetings", tags: [],
                      segments: [("Standup", 15, nil), ("Design review", 45, nil)],
                      pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [(20, "Agreed on the three-theme approach.")], learning: "", points: []),
            Blueprint(daysAgo: 4, hour: 9, title: "SwiftData deep dive", label: "Learning", tags: ["research"],
                      segments: [("WWDC session", 50, nil), ("Experiments", 70, "Deep work")],
                      pauseAfterMinutes: 60, pauseMinutes: 15,
                      notes: [(30, "CloudKit requires optional relationships with inverses."), (100, "No unique constraints with CloudKit.")],
                      learning: "SwiftData + CloudKit needs defaults on every attribute and no unique constraints.",
                      points: [("All attributes need defaults for CloudKit", ["research", "coding"], 4),
                               ("Ordered relationships aren't supported", ["research"], 3)]),
            Blueprint(daysAgo: 6, hour: 13, title: "Groceries and errands", label: "Errands", tags: ["family"],
                      segments: [("Shopping", 30, nil)], pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [], learning: "", points: [], personal: true),
            Blueprint(daysAgo: 7, hour: 9, title: "Session engine", label: "Deep work", tags: ["coding"],
                      segments: [("State machine", 80, nil), ("Unit tests", 60, nil), ("Docs", 20, nil)],
                      pauseAfterMinutes: 90, pauseMinutes: 20,
                      notes: [(15, "Compute elapsed from timestamps, never increment counters."), (150, "All tests green.")],
                      learning: "Timestamp-based math makes sleep and relaunch trivial.",
                      points: [("Derive elapsed time from wall-clock dates", ["coding"], 5)]),
            Blueprint(daysAgo: 9, hour: 11, title: "Charts exploration", label: "Learning", tags: ["research", "coding"],
                      segments: [("BarMark stacking", 40, nil), ("Heatmap", 35, nil)],
                      pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [(50, "RectangleMark works well for weekday × hour.")],
                      learning: "Swift Charts handles stacking automatically with foregroundStyle(by:).",
                      points: [("Use foregroundStyle(by:) for stacked bars", ["coding"], 2)], personal: true),
            Blueprint(daysAgo: 11, hour: 15, title: "Customer call", label: "Meetings", tags: ["review"],
                      segments: [("Call", 50, nil)], pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [(10, "They want CSV export."), (40, "Follow up on Friday.")], learning: "", points: []),
            Blueprint(daysAgo: 13, hour: 9, title: "Writing the README", label: "Deep work", tags: ["writing"],
                      segments: [("Setup steps", 45, nil), ("Architecture", 50, nil)],
                      pauseAfterMinutes: 40, pauseMinutes: 5,
                      notes: [(60, "Mention the local entitlements file.")],
                      learning: "Write setup docs while the steps are fresh.",
                      points: [("Document setup immediately", ["writing"], 3)]),
            Blueprint(daysAgo: 15, hour: 10, title: "Code review backlog", label: "Admin & email", tags: ["review"],
                      segments: [("PR #12", 30, nil), ("PR #15", 25, nil)], pauseAfterMinutes: nil, pauseMinutes: 0,
                      notes: [], learning: "", points: [("Smaller PRs get reviewed faster", ["review"], 2)]),
            Blueprint(daysAgo: 17, hour: 9, title: "Family budget", label: "Planning", tags: ["family"],
                      segments: [("Draft", 60, nil), ("Refine", 30, nil)], pauseAfterMinutes: 50, pauseMinutes: 10,
                      notes: [(20, "Keep it to three categories.")], learning: "Fewer categories, clearer picture.",
                      points: [], personal: true),
            Blueprint(daysAgo: 20, hour: 22, title: "Late-night bug hunt", label: "Deep work", tags: ["coding"],
                      segments: [("Repro", 70, nil), ("Fix", 80, nil)], pauseAfterMinutes: 100, pauseMinutes: 10,
                      notes: [(30, "Crash only happens across midnight."), (140, "Fixed: clip to day intervals.")],
                      learning: "Always clip durations to day windows for stats.",
                      points: [("Clip durations at midnight for per-day stats", ["coding"], 3)]),
        ]

        let calendar = Calendar.current
        let today = Date.now.startOfDay
        for (index, bp) in blueprints.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -bp.daysAgo, to: today),
                  let start = calendar.date(byAdding: .hour, value: bp.hour, to: day) else { continue }
            let session = WorkSession(startedAt: start, title: bp.title)
            context.insert(session)
            session.profile = bp.personal ? personal : work
            session.label = label(bp.label)
            session.tagList = bp.tags.compactMap { anyTag($0) }

            var cursor = start
            var segments: [Segment] = []
            for (i, spec) in bp.segments.enumerated() {
                let segment = Segment(startedAt: cursor, sortIndex: i, focus: spec.0)
                context.insert(segment)
                segment.label = spec.2.flatMap { label($0) } ?? session.label
                segment.session = session
                cursor = cursor.addingTimeInterval(TimeInterval(spec.1 * 60))
                segment.endedAt = cursor
                segments.append(segment)
            }
            var pauses: [PauseInterval] = []
            if let after = bp.pauseAfterMinutes, bp.pauseMinutes > 0 {
                let pStart = start.addingTimeInterval(TimeInterval(after * 60))
                pauses.append(PauseInterval(start: pStart, end: pStart.addingTimeInterval(TimeInterval(bp.pauseMinutes * 60))))
                cursor = cursor.addingTimeInterval(TimeInterval(bp.pauseMinutes * 60))
                segments.last?.endedAt = cursor
            }
            session.pauseIntervals = pauses
            session.endedAt = cursor

            for (minute, text) in bp.notes {
                let note = Note(text: text, createdAt: start.addingTimeInterval(TimeInterval(minute * 60)))
                context.insert(note)
                note.session = session
                note.segment = session.segment(containing: note.createdAt)
            }
            session.learningText = bp.learning
            for (i, point) in bp.points.enumerated() {
                let lp = LearningPoint(text: point.0, createdAt: cursor, sortIndex: i)
                context.insert(lp)
                lp.tagList = point.1.compactMap { anyTag($0) }
                lp.mastery = point.2
                lp.session = session
            }
            if index == 0 {
                session.overlaySummary = "Override canBecomeKey for text input in non-activating panels."
                session.showInOverlay = true
            }
            SessionEditor.normalize(session)
            session.recomputeStoredDuration(now: cursor)
        }

        do {
            try context.save()
        } catch {
            Log.persistence.error("PreviewData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// First ended session (by startedAt desc) in AppServices.preview's context.
    static var sampleSession: WorkSession {
        var descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate<WorkSession> { $0.endedAt != nil },
            sortBy: [SortDescriptor(\WorkSession.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let session = try? AppServices.preview.container.mainContext.fetch(descriptor).first else {
            fatalError("PreviewData: no sample session (populate failed)")
        }
        return session
    }
}
