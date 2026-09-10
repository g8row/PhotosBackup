import XCTest
@testable import PhotosBackup

/// The crash-loop guard: a row the process dies on while preparing must not
/// be what every relaunch restarts first, or one bad item closes the app on
/// every open and nothing else backs up (issue #13).
@MainActor
final class PreparationGuardTests: XCTestCase {
    private let account = "person@gmail.com"

    private func settle(timeout: TimeInterval = 5, until condition: () -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    /// Stays in its preparation phase until cancelled — where the process is
    /// when an export takes it down.
    private func hangingWorker() -> UploadWorker {
        { _, _, _, _, emit in
            await emit(.state(.exporting))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    private func armedQueue(_ worker: @escaping UploadWorker,
                            persistence: MemoryUploadQueuePersistence,
                            markers: MemoryPreparationMarkers) -> UploadQueue {
        let queue = UploadQueue(worker: worker, maxConcurrent: 1, persistence: persistence,
                                preparationMarkers: markers)
        queue.setPreparationGuardArmed(true)
        return queue
    }

    /// The process dying: copy the durable state as it is at that instant and
    /// build a fresh queue over the copy. The old queue keeps its originals.
    private func relaunch(_ persistence: MemoryUploadQueuePersistence, _ markers: MemoryPreparationMarkers,
                          worker: @escaping UploadWorker)
        -> (UploadQueue, MemoryUploadQueuePersistence, MemoryPreparationMarkers) {
        let persistence = MemoryUploadQueuePersistence(snapshot: persistence.snapshot)
        let markers = MemoryPreparationMarkers(markers.ids)
        return (armedQueue(worker, persistence: persistence, markers: markers), persistence, markers)
    }

    func testARowBeingPreparedIsMarkedUntilItFinishes() async {
        let markers = MemoryPreparationMarkers()
        let queue = armedQueue(WorkerScript([.block]).worker(),
                               persistence: MemoryUploadQueuePersistence(), markers: markers)
        queue.activateAccount(account)
        queue.enqueue([.asset(localIdentifier: "a")])
        let id = queue.items[0].id

        await settle { markers.ids == [id] }
        queue.cancel(id)
        await settle { markers.ids.isEmpty }
    }

    func testNothingIsMarkedWhileTheGuardIsDisarmed() async {
        let markers = MemoryPreparationMarkers()
        let queue = UploadQueue(worker: hangingWorker(), maxConcurrent: 1,
                                persistence: MemoryUploadQueuePersistence(), preparationMarkers: markers)
        queue.activateAccount(account)
        queue.enqueue([.asset(localIdentifier: "a")])

        await settle { queue.items.first?.state == .exporting }
        XCTAssertTrue(markers.ids.isEmpty)
        queue.cancelAll()
    }

    /// Leaving the foreground freezes an export rather than crashing it.
    func testDisarmingClearsTheMarkersOfRowsStillRunning() async {
        let markers = MemoryPreparationMarkers()
        let queue = armedQueue(hangingWorker(), persistence: MemoryUploadQueuePersistence(), markers: markers)
        queue.activateAccount(account)
        queue.enqueue([.asset(localIdentifier: "a")])
        await settle { !markers.ids.isEmpty }

        queue.setPreparationGuardArmed(false)
        XCTAssertTrue(markers.ids.isEmpty)
        queue.cancelAll()
    }

    func testAnExpiredWindowClearsTheMarkers() async {
        let markers = MemoryPreparationMarkers()
        let queue = armedQueue(hangingWorker(), persistence: MemoryUploadQueuePersistence(), markers: markers)
        queue.activateAccount(account)
        queue.enqueue([.asset(localIdentifier: "a")])
        await settle { !markers.ids.isEmpty }

        queue.suspendForBackgroundExpiration()
        XCTAssertTrue(markers.ids.isEmpty)
        queue.cancelAll()
    }

    /// Past preflight the bytes belong to an iOS transfer, which legitimately
    /// outlives the process.
    func testAPreparedCheckpointClearsTheMarker() async {
        let prepared = PreparedUpload(uploadURL: URL(string: "https://example.com/upload")!,
                                      hash: Data(repeating: 1, count: 20), filename: "IMG.JPG",
                                      modified: Date(timeIntervalSince1970: 1), byteCount: 1, receipt: nil)
        let checkpoint = UploadCheckpoint(filePath: "/tmp/IMG.JPG", filename: "IMG.JPG",
                                          modified: prepared.modified, byteCount: 1, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let worker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let markers = MemoryPreparationMarkers()
        let queue = armedQueue(worker, persistence: MemoryUploadQueuePersistence(), markers: markers)
        queue.activateAccount(account)
        queue.enqueue([.asset(localIdentifier: "a")])

        await settle { queue.items.first?.checkpoint == checkpoint }
        XCTAssertTrue(markers.ids.isEmpty)
        queue.cancelAll()
    }

    func testTheFirstInterruptionMovesTheRowBehindTheRest() async {
        let persistence = MemoryUploadQueuePersistence()
        let markers = MemoryPreparationMarkers()
        let first = armedQueue(hangingWorker(), persistence: persistence, markers: markers)
        first.activateAccount(account)
        first.enqueue([.asset(localIdentifier: "crashes"), .asset(localIdentifier: "fine")])
        let crashing = first.items[0].id
        await settle { markers.ids == [crashing] }

        let script = WorkerScript([])
        let (restored, restoredPersistence, restoredMarkers) = relaunch(persistence, markers, worker: script.worker())
        restored.setNetworkAccess(allowed: false, pauseReason: "Holding for inspection")
        restored.activateAccount(account)

        XCTAssertEqual(restored.items.map(\.source),
                       [.asset(localIdentifier: "fine"), .asset(localIdentifier: "crashes")])
        XCTAssertEqual(restored.items.last?.interruptedPreparations, 1)
        XCTAssertEqual(restored.items.last?.state, .queued)
        XCTAssertTrue(restoredMarkers.ids.isEmpty)
        XCTAssertEqual(restoredPersistence.snapshot?.items.last?.interruptedPreparations, 1)

        restored.setNetworkAccess(allowed: true)
        await settle { restored.isIdle }
        XCTAssertEqual(restored.items.map(\.state), [.done, .done])
        first.cancelAll()
    }

    func testASecondInterruptionSkipsTheRowUntilTheUserRetriesIt() async {
        let persistence = MemoryUploadQueuePersistence()
        let markers = MemoryPreparationMarkers()
        let first = armedQueue(hangingWorker(), persistence: persistence, markers: markers)
        first.activateAccount(account)
        first.enqueue([.asset(localIdentifier: "crashes")])
        let crashing = first.items[0].id
        await settle { markers.ids == [crashing] }

        // Second life: it dies on the same row again.
        let (second, secondPersistence, secondMarkers) = relaunch(persistence, markers, worker: hangingWorker())
        second.activateAccount(account)
        XCTAssertEqual(second.items.first?.interruptedPreparations, 1)
        await settle { secondMarkers.ids == [crashing] }

        let script = WorkerScript([])
        let (third, thirdPersistence, _) = relaunch(secondPersistence, secondMarkers, worker: script.worker())
        third.activateAccount(account)

        guard case .failed(_, let retryable) = third.items.first?.state else {
            return XCTFail("expected the row to be skipped, got \(String(describing: third.items.first?.state))")
        }
        XCTAssertFalse(retryable)
        XCTAssertEqual(thirdPersistence.snapshot?.items.first?.failureRetryable, false)
        // Automatic retries must leave it alone, or the loop starts again.
        XCTAssertEqual(third.retryRetryableFailures(), 0)
        XCTAssertEqual(script.calls, 0)

        // An explicit retry gets a fresh allowance.
        third.retry(crashing)
        await settle { third.items.first?.state == .done }
        XCTAssertEqual(third.items.first?.interruptedPreparations, 0)
        first.cancelAll()
        second.cancelAll()
    }

    func testMarkersFromAnotherQueueDoNotAffectRestoredRows() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount(account)
        first.enqueue([.asset(localIdentifier: "a")])

        let markers = MemoryPreparationMarkers([UUID()])
        let (restored, _, restoredMarkers) = relaunch(persistence, markers, worker: WorkerScript([]).worker())
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount(account)

        XCTAssertEqual(restored.items.first?.interruptedPreparations, 0)
        XCTAssertEqual(restored.items.first?.state, .queued)
        XCTAssertTrue(restoredMarkers.ids.isEmpty)
    }
}
