import XCTest
@testable import PhotosBackup

final class ContinuedBackupTests: XCTestCase {

    func testTheTaskContinuesOnlyWhileTheQueueCanMoveOnItsOwn() {
        func decide(workable: Bool = true, user: Bool = false, halted: Bool = false,
                    network: Bool = false, system: Bool = false) -> Bool {
            ContinuedBackupPolicy.shouldContinue(hasWorkableItems: workable, userPaused: user, halted: halted,
                                                 networkPaused: network, systemPaused: system)
        }
        XCTAssertTrue(decide())
        XCTAssertFalse(decide(workable: false), "nothing left, or only rows waiting for iCloud")
        XCTAssertFalse(decide(user: true))
        XCTAssertFalse(decide(halted: true), "the account needs the user")
        XCTAssertFalse(decide(network: true), "no allowed connection")
        XCTAssertFalse(decide(system: true))
    }

    /// A processing window ends once: either the run finishes or the expiry
    /// fallback hands it back, never both.
    func testOnlyOneEndingCompletesABackgroundWindow() async {
        let completion = BackgroundTaskCompletion()
        let claims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { completion.claim() } }
            return await group.reduce(into: 0) { total, claimed in if claimed { total += 1 } }
        }
        XCTAssertEqual(claims, 1)
        XCTAssertFalse(completion.claim())
    }

    func testARenamedBundleLeadsWithItsOwnIDWhenABroadWildcardPermitsIt() {
        // SideStore signs com.g8row.photosbackup as com.g8row.photosbackup.TEAM
        // and leaves the plist as built.
        let permitted = [
            "com.g8row.photosbackup.background-backup",
            "com.g8row.photosbackup.continued-backup.*",
            "com.g8row.photosbackup.*",
        ]
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: "com.g8row.photosbackup.TEAM",
                                                                permitted: permitted),
                       ["com.g8row.photosbackup.TEAM.continued-backup.", "com.g8row.photosbackup.continued-backup."])
    }

    func testAnUnrenamedBundleUsesItsOwnEntryOnce() {
        let permitted = ["com.g8row.photosbackup.continued-backup.*", "com.g8row.photosbackup.*"]
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: "com.g8row.photosbackup",
                                                                permitted: permitted),
                       ["com.g8row.photosbackup.continued-backup."])
    }

    func testWithoutABroadWildcardARenamedBundleFallsBackToTheBuildTimeEntry() {
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: "com.g8row.photosbackup.TEAM",
                                                                permitted: ["com.g8row.photosbackup.continued-backup.*"]),
                       ["com.g8row.photosbackup.continued-backup."])
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: "com.g8row.photosbackup",
                                                                permitted: ["com.g8row.photosbackup.background-backup"]),
                       [])
    }

    func testTheShippedPlistPermitsTheRunningBundleIDAndNotTheProcessingTask() throws {
        let bundle = Bundle(for: UploadQueue.self)
        let permitted = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        let id = try XCTUnwrap(bundle.bundleIdentifier)
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: id, permitted: permitted).first,
                       id + ".continued-backup.")
        // As SideStore would rename it: the build-time entry is the one left.
        XCTAssertEqual(ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: id + ".TEAMID", permitted: permitted),
                       [id + ".continued-backup."])
        // No entry may cover the processing task's identifier: with one, iOS
        // refused to register that task's handler.
        let processing = AutomaticBackupCoordinator.taskIdentifier
        XCTAssertFalse(permitted.contains { $0.hasSuffix("*") && processing.hasPrefix(String($0.dropLast())) })
    }

    /// SideStore rewrites the declared identifiers to its renamed bundle; the
    /// processing task registers under whatever this install declares.
    func testTheProcessingTaskUsesTheIdentifierThisInstallDeclares() {
        XCTAssertEqual(AutomaticBackupCoordinator.resolveTaskIdentifier(permitted: [
            "com.g8row.photosbackup.TEAM.background-backup",
            "com.g8row.photosbackup.TEAM.continued-backup.*",
        ]), "com.g8row.photosbackup.TEAM.background-backup")
        XCTAssertEqual(AutomaticBackupCoordinator.resolveTaskIdentifier(permitted: [
            "com.g8row.photosbackup.background-backup", "com.g8row.photosbackup.continued-backup.*",
        ]), "com.g8row.photosbackup.background-backup")
        XCTAssertEqual(AutomaticBackupCoordinator.resolveTaskIdentifier(permitted: []),
                       AutomaticBackupCoordinator.builtTaskIdentifier)
    }

    func testTheHeartbeatMovesProgressInsideTheItemInFlightOnly() {
        let units = ContinuedBackupProgress.unitsPerItem
        let twoOfTen = ContinuedBackupProgress(settledSinceStart: 2, unfinished: 8)
        // Real progress jumps to the finished items; a heartbeat adds one unit.
        XCTAssertEqual(twoOfTen.nextReported(after: 0, heartbeat: false), 2 * units)
        XCTAssertEqual(twoOfTen.nextReported(after: 2 * units, heartbeat: true), 2 * units + 1)
        // Never reaches the next finished item, however long the item takes.
        XCTAssertEqual(twoOfTen.nextReported(after: 3 * units - 1, heartbeat: true), 3 * units - 1)
        // Never goes backwards when real progress catches up.
        XCTAssertEqual(ContinuedBackupProgress(settledSinceStart: 3, unfinished: 7)
                        .nextReported(after: 3 * units - 1, heartbeat: false), 3 * units)
        // All done: exactly the total, heartbeat or not.
        let done = ContinuedBackupProgress(settledSinceStart: 10, unfinished: 0)
        XCTAssertEqual(done.nextReported(after: 9 * units + 500, heartbeat: true), 10 * units)
    }

    func testProgressCountsWhatFinishedAgainstWhatFinishedPlusWhatIsLeft() {
        let progress = ContinuedBackupProgress(settledSinceStart: 12, unfinished: 1308)
        XCTAssertEqual(progress.completed, 12)
        XCTAssertEqual(progress.total, 1320)
        XCTAssertEqual(progress.subtitle(waitingFor: nil), "\(12.formatted()) of \(1320.formatted()) done")
        XCTAssertEqual(progress.subtitle(waitingFor: "Waiting"), "Waiting")
        XCTAssertEqual(ContinuedBackupProgress(settledSinceStart: -3, unfinished: 5).completed, 0)
    }
}
