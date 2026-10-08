import Foundation
import Observation
import SwiftData

/// Caches the Stats snapshot and result. The snapshot is rebuilt only when the data changes; changing the range or
/// bucket recomputes from the cached snapshot. The aggregation runs in a detached task, off the main actor.
@MainActor @Observable
final class StatsModel {
    private(set) var result: StatsResult?
    private(set) var isComputing = false
    /// True once at least one session exists in the shown profile(s) (independent of the range).
    private(set) var hasAnySession = false

    @ObservationIgnored private var snapshot: StatsSnapshot?
    @ObservationIgnored private var snapshotVersion: Int = -1
    @ObservationIgnored private var snapshotScope: ProfileScope?
    @ObservationIgnored private var generation = 0

    init() {}

    /// - Parameters:
    ///   - sessions: every session (the view's @Query).
    ///   - scope: the profile(s) shown; sessions outside it are left out. `.allProfiles` keeps every session.
    ///   - dataVersion: bumped by the view whenever the data may have changed.
    func refresh(sessions: [WorkSession], scope: ProfileScope, dataVersion: Int, options: StatsOptions) async {
        generation += 1
        let myGeneration = generation

        if snapshot == nil || snapshotVersion != dataVersion || snapshotScope != scope {
            let scoped = scope.isAllProfiles ? sessions : scope.filter(sessions)
            snapshot = StatsSnapshot.make(from: scoped, now: .now)
            snapshotVersion = dataVersion
            snapshotScope = scope
        }
        guard let snapshot else { return }
        hasAnySession = !snapshot.sessions.isEmpty

        isComputing = true
        let computed = await Task.detached(priority: .userInitiated) {
            StatsCalculator.compute(snapshot, options: options)
        }.value

        // A newer request finished first or is still running: drop this one.
        guard myGeneration == generation else { return }
        result = computed
        isComputing = false
    }
}
