import XCTest
@testable import Worklog

final class BackupRetentionTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 12))!
    }

    private func file(_ name: String, _ offset: TimeInterval, reason: BackupReason = .scheduled,
                      sessions: Int? = nil, pinned: Bool = false) -> BackupFile {
        BackupFile(url: URL(filePath: "/tmp/backups/\(name).json"), date: now.addingTimeInterval(offset), sizeBytes: 1,
                   reason: reason.rawValue, sessionCount: sessions, isPinned: pinned)
    }

    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    func testTieredRetention() {
        var files = [
            file("a1", -1 * hour), file("a2", -2 * hour), file("a3", -3 * hour),
            file("a4", -4 * hour), file("a5", -5 * hour),                       // same day as a1, beyond newest 3
            file("d", -3 * day), file("d2", -3 * day - hour),                    // daily tier: newest of that day only
            file("w", -30 * day), file("w2", -30 * day - 2 * hour),              // weekly tier
            file("old", -100 * day),                                             // beyond every tier
            file("pinnedOld", -200 * day, pinned: true),
            file("restoring", -300 * day),
            file("quit", -6 * hour, reason: .onQuit),                            // on-quit backups rotate like scheduled
        ]
        for index in 0..<25 {
            files.append(file("m\(index)", -Double(10 + index) * day, reason: index.isMultiple(of: 2) ? .manual : .beforeRestore))
        }

        let doomed = BackupService.filesToPrune(files, keepAutomatic: 3, now: now, calendar: calendar,
                                                protecting: URL(filePath: "/tmp/backups/restoring.json"))
        let names = Set(doomed.map { $0.url.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(names, ["a4", "a5", "quit", "d2", "w2", "old", "m20", "m21", "m22", "m23", "m24"])
    }

    func testNewestBackupWithSessionsIsNeverPruned() {
        let files = [
            file("e1", -1 * hour, sessions: 0), file("e2", -2 * hour, sessions: 0), file("e3", -3 * hour, sessions: 0),
            file("e4", -4 * hour, sessions: 0),
            file("full", -70 * day, sessions: 42),      // outside the daily and weekly windows
            file("fullOlder", -80 * day, sessions: 40),
        ]
        let doomed = BackupService.filesToPrune(files, keepAutomatic: 3, now: now, calendar: calendar, protecting: nil)
        XCTAssertEqual(Set(doomed.map { $0.url.deletingPathExtension().lastPathComponent }), ["e4", "fullOlder"])
    }

    func testShrinkageGuard() {
        XCTAssertTrue(BackupService.shouldPinPrevious(previousCount: 40, newCount: 10))
        XCTAssertTrue(BackupService.shouldPinPrevious(previousCount: 3, newCount: 0))
        XCTAssertFalse(BackupService.shouldPinPrevious(previousCount: 40, newCount: 20))
        XCTAssertFalse(BackupService.shouldPinPrevious(previousCount: 8, newCount: 2), "small stores don't trigger")
        XCTAssertFalse(BackupService.shouldPinPrevious(previousCount: 0, newCount: 0))
    }

    func testFileNamesParseNewUTCAndOldLocalFormats() throws {
        let new = BackupService.parse(filename: "Worklog-Backup-2026-10-07T14-03-22Z-scheduled-n42-2-pinned.json")
        XCTAssertEqual(new.reason, "scheduled")
        XCTAssertEqual(new.sessionCount, 42)
        XCTAssertTrue(new.isPinned)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 3, second: 22))
        XCTAssertEqual(new.date, expected, "new names are UTC")

        let old = BackupService.parse(filename: "Worklog-Backup-2026-10-07T14-03-22-beforeRestore-2.json")
        XCTAssertEqual(old.reason, "beforeRestore")
        XCTAssertNil(old.sessionCount)
        XCTAssertFalse(old.isPinned)
        let local = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 3, second: 22))
        XCTAssertEqual(old.date, local, "old names are local time")

        XCTAssertEqual(BackupService.parse(filename: "Worklog-Backup-garbage.json").reason, "unknown")
    }
}
