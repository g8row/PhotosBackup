import XCTest
@testable import PhotosBackup

final class DiagnosticEventLogTests: XCTestCase {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.json")
    }

    func testIdenticalConsecutiveEventsFoldIntoOneEntryWithACount() {
        let log = DiagnosticEventLog(url: temporaryURL(), limit: 10)
        log.record("upload", "Will retry", level: .warning)
        log.record("upload", "Will retry", level: .warning)
        log.record("upload", "Will retry", level: .warning)
        log.record("queue", "Queued 1")

        let events = log.snapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].occurrences, 3)
        let first = try? XCTUnwrap(events[0].firstDate)
        XCTAssertLessThanOrEqual(first ?? .distantFuture, events[0].date)
        XCTAssertEqual(events[1].occurrences, 1)
    }

    func testTheSameMessageAtADifferentLevelIsNotFolded() {
        let log = DiagnosticEventLog(url: temporaryURL(), limit: 10)
        log.record("queue", "Paused")
        log.record("queue", "Paused", level: .warning)
        XCTAssertEqual(log.snapshot().count, 2)
    }

    /// A long healthy backup must not push out the one failure that explains
    /// a report.
    func testAFullLogDropsRoutineEntriesBeforeWarningsAndErrors() {
        let log = DiagnosticEventLog(url: temporaryURL(), limit: 3)
        log.record("upload", "failure A", level: .error)
        log.record("queue", "routine 1")
        log.record("queue", "routine 2")
        log.record("queue", "routine 3")
        log.record("queue", "routine 4")
        XCTAssertEqual(log.snapshot().map(\.message), ["failure A", "routine 3", "routine 4"])
    }

    func testALogOfOnlyProblemsDropsTheOldestProblem() {
        let log = DiagnosticEventLog(url: temporaryURL(), limit: 2)
        log.record("upload", "e1", level: .error)
        log.record("upload", "e2", level: .warning)
        log.record("upload", "e3", level: .error)
        XCTAssertEqual(log.snapshot().map(\.message), ["e2", "e3"])
    }

    func testEventsSurviveARelaunchOnceFlushed() {
        let url = temporaryURL()
        let log = DiagnosticEventLog(url: url, limit: 10)
        log.record("lifecycle", "Launched")
        log.record("upload", "An upload failed", level: .error)
        log.flush()

        let reopened = DiagnosticEventLog(url: url, limit: 10)
        XCTAssertEqual(reopened.snapshot().map(\.message), ["Launched", "An upload failed"])
        XCTAssertEqual(reopened.snapshot().last?.level, .error)
    }

    func testEntriesOlderThanTheMaximumAgeAreDroppedOnLoad() throws {
        let url = temporaryURL()
        let old = DiagnosticEvent(date: Date().addingTimeInterval(-DiagnosticEventLog.maximumAge - 60),
                                  level: .error, category: "upload", message: "old")
        let recent = DiagnosticEvent(date: Date(), level: .info, category: "queue", message: "recent")
        try write([old, recent], to: url)

        XCTAssertEqual(DiagnosticEventLog(url: url).snapshot().map(\.message), ["recent"])
    }

    /// 0.3.6 development builds wrote entries without the repeat fields.
    func testALogWrittenBeforeRepeatsWereFoldedStillDecodes() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try Data(#"[{"date":"\#(stamp)","level":"warning","category":"scheduler","message":"expired"}]"#.utf8)
            .write(to: url)

        let events = DiagnosticEventLog(url: url).snapshot()
        XCTAssertEqual(events.map(\.message), ["expired"])
        XCTAssertEqual(events.first?.occurrences, 1)
    }

    func testClearRemovesEventsAndTheFile() {
        let url = temporaryURL()
        let log = DiagnosticEventLog(url: url)
        log.record("queue", "something")
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        log.clear()
        XCTAssertTrue(log.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordedTextIsRedactedBeforeItIsStored() {
        let log = DiagnosticEventLog(url: temporaryURL())
        log.record("account", "Connected person@gmail.com")
        XCTAssertEqual(log.snapshot().first?.message, "Connected <email>")
    }

    private func write(_ events: [DiagnosticEvent], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: url)
    }
}

final class DiagnosticRedactorTests: XCTestCase {
    func testRemovesPersonalDataButKeepsTheExplanation() {
        let input = "Google said: token=abc123 for person@gmail.com uploading IMG_1234.HEIC "
            + "from /var/mobile/Containers/Data/x.jpg at https://photos.googleapis.com/data?upload_id=XYZ "
            + "asset 7A1B2C3D-1111-2222-3333-444455556666/L0/001; Bearer ya29.secret"
        let output = DiagnosticRedactor.redact(input)

        for secret in ["abc123", "person@gmail.com", "IMG_1234", "/var/mobile", "googleapis", "7A1B2C3D", "ya29"] {
            XCTAssertFalse(output.contains(secret), "\(secret) survived: \(output)")
        }
        XCTAssertTrue(output.hasPrefix("Google said: token=<redacted>"), output)
        XCTAssertTrue(output.contains("<email>"), output)
        XCTAssertTrue(output.contains("<filename>"), output)
        XCTAssertTrue(output.contains("<id>"), output)
    }

    func testOrdinaryDiagnosticTextIsLeftAlone() {
        let text = "Queued 3 new items; the queue holds 10, 4 unfinished (Wi-Fi; battery 54%, charging; HTTP 400)"
        XCTAssertEqual(DiagnosticRedactor.redact(text), text)
    }
}

final class AutomaticBackupRunHistoryTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suite = "run-history-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEachRunClosesItsOwnRecordWhenRunsOverlap() {
        let window = AutomaticBackupRunHistory.started(.backgroundProcessing, context: "app in background",
                                                       defaults: defaults, now: Date(timeIntervalSince1970: 1_000))
        let shortcut = AutomaticBackupRunHistory.started(.shortcut, defaults: defaults,
                                                         now: Date(timeIntervalSince1970: 1_010))
        AutomaticBackupRunHistory.finished(window, success: true, summary: "enqueued 2",
                                           defaults: defaults, now: Date(timeIntervalSince1970: 1_100))

        let runs = AutomaticBackupRunHistory.recent(defaults: defaults)
        XCTAssertEqual(runs.map(\.source), [.shortcut, .backgroundProcessing])
        XCTAssertNil(runs[0].finishedAt)
        XCTAssertEqual(runs[1].summary, "enqueued 2")
        XCTAssertEqual(runs[1].success, true)
        XCTAssertEqual(runs[1].duration, 100)
        XCTAssertEqual(runs[1].context, "app in background")
        XCTAssertEqual(AutomaticBackupRunHistory.latest(.shortcut, defaults: defaults)?.id, shortcut)
    }

    /// Opening the app is the most frequent run and says the least about
    /// background behaviour, so it must not push background windows out.
    func testTrimmingDropsFinishedAppOpenRunsBeforeBackgroundWindows() {
        let window = AutomaticBackupRunHistory.started(.backgroundProcessing, defaults: defaults)
        AutomaticBackupRunHistory.finished(window, success: true, summary: "ok", defaults: defaults)
        for _ in 0..<AutomaticBackupRunHistory.limit {
            let run = AutomaticBackupRunHistory.started(.foreground, defaults: defaults)
            AutomaticBackupRunHistory.finished(run, success: true, summary: "ok", defaults: defaults)
        }

        let runs = AutomaticBackupRunHistory.recent(defaults: defaults)
        XCTAssertEqual(runs.count, AutomaticBackupRunHistory.limit)
        XCTAssertTrue(runs.contains { $0.id == window })
    }

    func testContextIsRedacted() {
        AutomaticBackupRunHistory.started(.shortcut, context: "network Wi-Fi; person@gmail.com", defaults: defaults)
        XCTAssertEqual(AutomaticBackupRunHistory.recent(defaults: defaults).first?.context, "network Wi-Fi; <email>")
    }
}

final class AppSessionTrackerTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suite = "session-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheFirstLaunchHasNothingToReport() {
        XCTAssertNil(AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults))
    }

    func testDyingWhileOpenIsReportedOnTheNextLaunch() {
        AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        AppSessionTracker.note(.active, defaults: defaults)

        let outcome = AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        XCTAssertEqual(outcome?.level, .error)
        XCTAssertEqual(AppSessionTracker.previousSessionOutcome(defaults: defaults), outcome?.message)
    }

    func testDyingWhileStartingIsReported() {
        AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        XCTAssertEqual(AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)?.level, .error)
    }

    func testDyingDuringABackgroundWindowIsReported() {
        AppSessionTracker.beginLaunch(inBackground: true, version: "1", defaults: defaults)
        AppSessionTracker.note(.backgroundWork, defaults: defaults)
        XCTAssertEqual(AppSessionTracker.beginLaunch(inBackground: true, version: "1", defaults: defaults)?.level, .error)
    }

    /// iOS terminating a suspended app is routine and must not read as a crash.
    func testAnOrdinaryTerminationInTheBackgroundIsNotReported() {
        AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        AppSessionTracker.note(.active, defaults: defaults)
        AppSessionTracker.note(.background, defaults: defaults)

        XCTAssertNil(AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults))
        XCTAssertNil(AppSessionTracker.previousSessionOutcome(defaults: defaults))
    }

    func testAnUpdateIsNotMistakenForACrash() {
        AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        AppSessionTracker.note(.active, defaults: defaults)

        let outcome = AppSessionTracker.beginLaunch(inBackground: false, version: "2", defaults: defaults)
        XCTAssertEqual(outcome?.level, .info)
        XCTAssertEqual(outcome?.message, "Updated from 1 to 2")
        XCTAssertNil(AppSessionTracker.previousSessionOutcome(defaults: defaults))
    }

    func testClosingFromTheAppSwitcherIsNotAnError() {
        AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)
        AppSessionTracker.note(.inactive, defaults: defaults)
        XCTAssertEqual(AppSessionTracker.beginLaunch(inBackground: false, version: "1", defaults: defaults)?.level, .info)
    }
}
