import XCTest
@testable import PhotosBackup

/// A scripted `UploadWorker`. Each call pops the next instruction, so a test
/// can say "fail twice, then succeed" without any network.
final class WorkerScript: @unchecked Sendable {
    enum Step {
        case succeed(UploadOutcome)
        case fail(Error)
        case block            // hang until cancelled
    }
    private let lock = NSLock()
    private var steps: [Step]
    private let fallback: Step
    private(set) var calls = 0
    private var inFlight = 0
    private(set) var peakInFlight = 0

    init(_ steps: [Step], fallback: Step = .succeed(.uploaded(mediaKey: "KEY"))) {
        self.steps = steps; self.fallback = fallback
    }

    func worker() -> UploadWorker {
        { [self] _, _, _, _, emit in
            let step: Step = lock.sync {
                calls += 1; inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
                return steps.isEmpty ? fallback : steps.removeFirst()
            }
            defer { lock.sync { inFlight -= 1 } }
            await emit(.described(name: "IMG_\(calls).JPG", byteCount: 1234))
            await emit(.state(.hashing(fraction: 1)))
            await emit(.state(.uploading(fraction: 0.5)))
            switch step {
            case .succeed(let outcome): return outcome
            case .fail(let error): throw error
            case .block:
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            }
        }
    }
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

/// What each worker call was told about the duplicate check, in call order.
final class SkipRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var calls: [Bool] { lock.sync { recorded } }
    func record(_ skipsDuplicateCheck: Bool) { lock.sync { recorded.append(skipsDuplicateCheck) } }
}

/// A queue sleeper that records each requested delay and holds every sleeper
/// until the test opens it.
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var delays: [Double] = []
    var requested: [Double] { lock.sync { delays } }

    func open() { lock.sync { isOpen = true } }

    func sleep(_ seconds: Double) async {
        lock.sync { delays.append(seconds) }
        while !lock.sync({ isOpen }) { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}

@MainActor
final class UploadQueueTests: XCTestCase {

    private func makeQueue(_ script: WorkerScript, maxConcurrent: Int = 2, maxAttempts: Int = 3) -> UploadQueue {
        // No real backoff: the retry delay is injected so the state machine runs
        // at full speed here.
        UploadQueue(worker: script.worker(), maxConcurrent: maxConcurrent, maxAttempts: maxAttempts,
                    sleeper: { _ in await Task.yield() })
    }

    private func settle(_ queue: UploadQueue, timeout: TimeInterval = 5,
                        until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("queue never settled: \(queue.items.map { "\($0.state)" })", file: file, line: line)
    }

    /// The queue's aggregates, its id→offset map and its scan cursor are all
    /// maintained incrementally so a full-library queue does not re-walk itself
    /// on every progress tick. That trades a `filter` for state that can drift,
    /// so check each aggregate against the definition it replaced.
    private func assertAggregatesMatchRows(_ queue: UploadQueue,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let rows = queue.items
        XCTAssertEqual(queue.activeCount, rows.filter { !$0.state.isFinished }.count,
                       "activeCount", file: file, line: line)
        XCTAssertEqual(queue.failedCount,
                       rows.filter { if case .failed = $0.state { return true }; return false }.count,
                       "failedCount", file: file, line: line)
        XCTAssertEqual(queue.deferredForICloudCount, rows.filter { $0.state == .waitingForICloud }.count,
                       "deferredForICloudCount", file: file, line: line)
        XCTAssertEqual(queue.isIdle, !rows.contains { !$0.state.isFinished },
                       "isIdle", file: file, line: line)
        XCTAssertEqual(queue.hasFinishedItems, rows.contains { $0.state.isFinished },
                       "hasFinishedItems", file: file, line: line)
        XCTAssertEqual(queue.hasWorkableItems,
                       rows.contains { !$0.state.isFinished && $0.state != .waitingForICloud },
                       "hasWorkableItems", file: file, line: line)
        let tracked = rows.filter { !$0.state.isFinished || $0.state == .done || $0.state == .alreadyBackedUp }
        let expected = tracked.isEmpty
            ? 0
            : tracked.reduce(0) { $0 + ($1.state.fraction ?? 0) } / Double(tracked.count)
        XCTAssertEqual(queue.overallFraction, expected, accuracy: 0.000_001,
                       "overallFraction", file: file, line: line)
    }

    private var oneSource: [MediaSource] { [.file(URL(fileURLWithPath: "/dev/null"))] }
    private func sources(_ n: Int) -> [MediaSource] {
        (0..<n).map { .file(URL(fileURLWithPath: "/tmp/item-\($0)")) }
    }

    func testSuccessfulItemEndsDoneWithTheNameAndKeyTheWorkerReported() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(queue.items.first?.mediaKey, "ABC")
        XCTAssertEqual(queue.items.first?.name, "IMG_1.JPG")
        XCTAssertEqual(queue.items.first?.byteCount, 1234)
        XCTAssertTrue(queue.isIdle)
    }

    func testARateLimitedRowPausesTheQueueInsteadOfFailing() async {
        let limited = GPMCError(kind: .server(429), message: "Google returned HTTP 429 during duplicate check.")
        let script = WorkerScript([.fail(limited)])
        let gate = SleepGate()
        // One attempt: without the pause, the first refusal would fail the row.
        let queue = UploadQueue(worker: script.worker(), maxConcurrent: 1, maxAttempts: 1,
                                sleeper: { await gate.sleep($0) })
        queue.enqueue(sources(2))
        // The pause reason is set before the waiting task starts, so waiting on
        // it alone raced the sleeper and saw no delay yet on a loaded machine.
        await settle(queue) { queue.rateLimitPauseReason != nil && !gate.requested.isEmpty }
        XCTAssertEqual(queue.items.map(\.state), [.queued, .queued])
        XCTAssertEqual(queue.pauseReason, queue.rateLimitPauseReason)
        XCTAssertEqual(gate.requested, [UploadQueue.rateLimitBaseDelay])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(script.calls, 1, "nothing starts while Google's limit is in force")

        gate.open()
        await settle(queue) { queue.isIdle }
        XCTAssertEqual(queue.items.map(\.state), [.done, .done])
        XCTAssertNil(queue.rateLimitPauseReason)
        XCTAssertEqual(queue.failedCount, 0)
        assertAggregatesMatchRows(queue)
    }

    func testTheRateLimitPauseGrowsWhileGoogleKeepsRefusingAndResetsAfterASuccess() async {
        let limited = GPMCError(kind: .server(429), message: "Google returned HTTP 429 during duplicate check.")
        let script = WorkerScript([.fail(limited), .fail(limited), .succeed(.uploaded(mediaKey: "A")), .fail(limited)])
        let gate = SleepGate()
        gate.open()
        let queue = UploadQueue(worker: script.worker(), maxConcurrent: 1, maxAttempts: 1,
                                sleeper: { await gate.sleep($0) })
        queue.enqueue(sources(2))
        await settle(queue) { queue.isIdle }
        let base = UploadQueue.rateLimitBaseDelay
        XCTAssertEqual(gate.requested, [base, base * 2, base])
        XCTAssertEqual(queue.items.map(\.state), [.done, .done])
    }

    func testSettledRowsKeepCountingWhenFinishedRowsAreCleared() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "A")),
                                   .fail(GPMCError(kind: .server(400), message: "rejected")),
                                   .succeed(.alreadyBackedUp(mediaKey: "B"))])
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.isIdle }
        XCTAssertEqual(queue.settledRowCount, 3, "done, failed and already backed up all settle a row")
        queue.clearFinished()
        XCTAssertEqual(queue.settledRowCount, 3)
    }

    func testAlreadyBackedUpIsItsOwnTerminalState() async {
        let script = WorkerScript([.succeed(.alreadyBackedUp(mediaKey: "OLD"))])
        let queue = makeQueue(script)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .alreadyBackedUp }
        XCTAssertEqual(queue.items.first?.mediaKey, "OLD")
        XCTAssertEqual(queue.failedCount, 0)
    }

    func testTransportFailuresRetryUpToMaxAttemptsThenFail() async {
        let error = GPMCError(kind: .transport, message: "Could not reach Google.")
        let script = WorkerScript([.fail(error), .fail(error), .fail(error)], fallback: .fail(error))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 3)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .failed(reason: "Could not reach Google.", retryable: true))
        XCTAssertEqual(script.calls, 3)
        XCTAssertEqual(queue.items.first?.attempts, 3)
    }

    func testARetryableFailureThatLaterSucceedsEndsDone() async {
        let script = WorkerScript([.fail(GPMCError(kind: .server(503), message: "busy")),
                                   .succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    func testNonRetryableFailureIsAttemptedOnce() async {
        let script = WorkerScript([.fail(GPMCError(kind: .malformed, message: "Google rejected the upload."))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .failed(reason: "Google rejected the upload.", retryable: false))
        XCTAssertEqual(script.calls, 1)
    }

    func testExporterFailureIsReportedVerbatimAndNotRetried() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.noResource)])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state,
                       .failed(reason: "That item has no file to upload.", retryable: false))
        XCTAssertEqual(script.calls, 1)
    }

    /// Freeing space deletes photos that may still be queued. Seen on device:
    /// about 2,000 rows failed "no longer in your photo library" after a
    /// library was cleared mid-run. Such a row is dropped, not failed.
    func testARowWhosePhotoWasDeletedIsDroppedNotFailed() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.missingAsset)])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.isIdle }
        XCTAssertEqual(queue.items.count, 1, "the deleted photo's row is gone")
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(queue.failedCount, 0)
        // The drop settles the row. A continued backup reports its total as
        // settled plus unfinished, so leaving the dropped row out of both
        // walked that total backwards mid-run.
        XCTAssertEqual(queue.settledRowCount, 2)
        XCTAssertEqual(script.calls, 2)
        assertAggregatesMatchRows(queue)
    }

    /// A `CancellationError` no `cancel` or requeue claimed is an interruption,
    /// not a decision — the app suspended mid-export, say. It used to land in a
    /// terminal `.cancelled` row labelled only "Cancelled", which explained
    /// nothing, stayed in the list for good, and showed up beside the same
    /// photo once a later scan backed it up (issue #19).
    func testAnUnclaimedCancellationRetriesThenSaysWhatHappened() async {
        let script = WorkerScript([], fallback: .fail(CancellationError()))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 3)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state,
                       .failed(reason: "Backing this item up kept being interrupted before it finished.",
                               retryable: true))
        XCTAssertEqual(script.calls, 3, "it is retried rather than given up on at once")
        assertAggregatesMatchRows(queue)
    }

    /// The common case: the interruption passes and the row backs up by itself.
    func testAnUnclaimedCancellationRecoversOnTheNextAttempt() async {
        let script = WorkerScript([.fail(CancellationError())])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(queue.failedCount, 0)
        assertAggregatesMatchRows(queue)
    }

    /// `.cancelled` now means one thing only, so the label may say so.
    func testOnlyTheUsersOwnCancellationReadsAsStopped() async {
        let script = WorkerScript([], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1)
        let ids = queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .uploading(fraction: 0.5) }
        queue.cancel(ids[0])
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .cancelled)
        XCTAssertEqual(queue.items.first?.state.label, "Stopped by you")
    }

    func testCredentialRejectionHaltsTheQueueAndLeavesWorkRequeued() async {
        let rejection = GPMCError(kind: .credentialRejected, message: "Connect the account again.")
        let script = WorkerScript([.fail(rejection)], fallback: .fail(rejection))
        let queue = makeQueue(script, maxConcurrent: 1)
        var reported: Error?
        queue.onCredentialRejected = { reported = $0 }
        queue.enqueue(sources(3))
        await settle(queue) { queue.haltReason != nil }
        XCTAssertEqual(queue.haltReason, "Connect the account again.")
        XCTAssertEqual((reported as? GPMCError)?.kind, .credentialRejected)
        // Nothing is marked failed: everything waits for the account to come back.
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .queued })
        // And the queue stays stopped rather than burning through the rest.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 1)
    }

    /// A full Google account stops the queue as hard as a refused credential,
    /// but reconnecting the account would fix nothing, so the app is not asked
    /// to send the user through sign-in again.
    func testAFullAccountHaltsTheQueueWithoutAskingForAReconnection() async {
        let full = GPMCError(kind: .storageFull, message: "The Google account is out of storage.")
        let script = WorkerScript([.fail(full)], fallback: .fail(full))
        let queue = makeQueue(script, maxConcurrent: 1)
        var reported: Error?
        queue.onCredentialRejected = { reported = $0 }
        queue.enqueue(sources(3))
        await settle(queue) { queue.haltReason != nil }
        XCTAssertEqual(queue.haltReason, "The Google account is out of storage.")
        XCTAssertNil(reported, "a full account is not a credential problem")
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .queued })
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 1)
    }

    /// The failure log outlives the rows. Retry and Clear Finished both take the
    /// reason away, which is exactly when someone goes looking for it.
    func testTheFailureLogOutlivesTheRowsAndCountsWhatItDropped() async {
        let failure = GPMCError(kind: .server(400), message: "Google returned HTTP 400 during finalization.")
        let script = WorkerScript([], fallback: .fail(failure))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished } }

        XCTAssertEqual(queue.failureCount, 3)
        XCTAssertEqual(queue.recentFailures.count, 3)
        XCTAssertTrue(queue.recentFailures.allSatisfy { $0.reason.contains("during finalization") })
        XCTAssertTrue(queue.recentFailures[0].summary.contains("during finalization"))

        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.recentFailures.count, 3, "clearing the rows must not clear the record")
        XCTAssertEqual(queue.failureCount, 3)
    }

    func testTheFailureLogIsBoundedAndNewestFirst() async {
        let script = WorkerScript([], fallback: .fail(GPMCError(kind: .server(400), message: "rejected")))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(30))
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(queue.failureCount, 30)
        XCTAssertEqual(queue.recentFailures.count, 25)
        XCTAssertEqual(queue.recentFailures.first?.name, queue.items.last?.name,
                       "newest first, so the last row to fail is at the top")
    }

    func testResumeAfterAHaltPicksTheQueueBackUp() async {
        let rejection = GPMCError(kind: .credentialRejected, message: "Connect the account again.")
        let script = WorkerScript([.fail(rejection)], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.haltReason != nil }
        queue.resume()
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertNil(queue.haltReason)
    }

    func testNetworkPolicyPauseHoldsNewWorkAndResumesAutomatically() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        queue.enqueue(oneSource)

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 0)
        XCTAssertEqual(queue.items.first?.state, .queued)
        XCTAssertEqual(queue.networkPauseReason, "Waiting for Wi-Fi")

        queue.setNetworkAccess(allowed: true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 1)
        XCTAssertNil(queue.networkPauseReason)
    }

    func testLosingAllowedNetworkRequeuesInFlightWork() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        await settle(queue) { queue.items.first?.state == .queued }
        XCTAssertEqual(script.calls, 1)

        queue.setNetworkAccess(allowed: true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    func testBackgroundExpirationRequeuesWorkForTheNextExecutionWindow() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.suspendForBackgroundExpiration()
        await settle(queue) { queue.items.first?.state == .queued }
        XCTAssertNotNil(queue.systemPauseReason)

        queue.resumeSystemWork()
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertNil(queue.systemPauseReason)
        XCTAssertEqual(script.calls, 2)
    }

    func testBackgroundExpirationDoesNotCancelAnIOSOwnedFileTransfer() async {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 1, count: 20),
            filename: "photo.jpg", modified: Date(), byteCount: 10,
            receipt: nil
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/photo.jpg", filename: "photo.jpg",
                                          modified: Date(), byteCount: 10, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let worker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            await emit(.state(.uploading(fraction: 0.25)))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let queue = UploadQueue(worker: worker, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.checkpoint == checkpoint }

        queue.suspendForBackgroundExpiration()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(queue.items.first?.state, .uploading(fraction: 0.25))
        XCTAssertEqual(queue.items.first?.checkpoint, checkpoint)
        queue.cancelAll()
        await settle(queue) { queue.items.isEmpty }
    }

    func testURLSessionRelaunchOnlyPumpsCheckpointedTransfers() async {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 3, count: 20),
            filename: "ready.jpg", modified: Date(), byteCount: 10,
            receipt: Data([1, 0])
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/ready.jpg", filename: "ready.jpg",
                                          modified: Date(), byteCount: 10, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let normalID = UUID()
        let readyID = UUID()
        let persistence = MemoryUploadQueuePersistence(snapshot: UploadQueueSnapshot(
            version: UploadQueueSnapshot.version,
            accountIdentifier: "person@gmail.com",
            items: [
                PersistedUploadItem(id: normalID, source: .asset("normal"), name: "normal.jpg",
                                    byteCount: 0, attempts: 0, failureReason: nil, failureRetryable: false),
                PersistedUploadItem(id: readyID, source: .asset("ready"), name: "ready.jpg",
                                    byteCount: 10, attempts: 0, failureReason: nil, failureRetryable: false,
                                    checkpoint: checkpoint)
            ],
            completedSourceKeys: []
        ))
        let queue = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        queue.setNetworkAccess(allowed: false, pauseReason: "Checking")
        queue.resumeBackgroundTransferCompletions()
        queue.activateAccount("person@gmail.com")
        queue.setNetworkAccess(allowed: true)

        await settle(queue) { queue.items.first(where: { $0.id == readyID })?.state == .done }
        XCTAssertEqual(queue.items.first(where: { $0.id == normalID })?.state, .queued)
    }

    func testCloudOnlyAssetWaitsWithoutSpendingAnAttemptAndResumesInForeground() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.iCloudDownloadRequired)],
                                  fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setICloudDownloadsAllowed(false)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .waitingForICloud }
        XCTAssertEqual(queue.items.first?.attempts, 0)

        queue.setICloudDownloadsAllowed(true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    /// The foreground run waits on this rather than `activeCount`. A row parked
    /// on an iCloud download never finishes on its own, so counting it as work
    /// in progress held the run's wait loop open forever and the rest of the
    /// selection was never enqueued.
    func testICloudDeferredRowsAreNotCountedAsWorkTheRunCanWaitOn() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.iCloudDownloadRequired)],
                                  fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setICloudDownloadsAllowed(false)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished || $0.state == .waitingForICloud } }

        XCTAssertEqual(queue.deferredForICloudCount, 1)
        XCTAssertEqual(queue.activeCount, 1, "the deferred row is still unfinished")
        XCTAssertFalse(queue.hasWorkableItems, "but nothing here can progress without a foreground download")
    }

    /// "Back Up Now" and "Re-check Backups" pass no limit, so the count they
    /// report is the whole selection and nothing is left off-queue.
    func testEnqueueWithoutALimitAcceptsEverySource() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        let accepted = queue.enqueue(sources(600), skippingExisting: true)
        XCTAssertEqual(accepted.count, 600)
        XCTAssertEqual(queue.items.count, 600)
    }

    func testAutomaticEnqueueSkipsSourcesAlreadyTrackedOrRepeatedInOneBatch() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        let source = MediaSource.file(URL(fileURLWithPath: "/tmp/repeated"))

        let first = queue.enqueue([source, source], skippingExisting: true)
        let second = queue.enqueue([source], skippingExisting: true)

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
    }

    func testAutomaticEnqueueDoesNotDuplicateAnExistingFailedSource() async {
        let failure = GPMCError(kind: .malformed, message: "bad media")
        let script = WorkerScript([.fail(failure)], fallback: .fail(failure))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.file(URL(fileURLWithPath: "/tmp/permanent-failure"))

        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        let second = queue.enqueue([source], skippingExisting: true)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(script.calls, 1)
    }

    func testUploadProcessingPreferencesSurviveRelaunch() {
        let suite = "UploadQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = BackupPreferences(defaults: defaults)
        first.storageSaver = true
        first.useQuota = true

        let restored = BackupPreferences(defaults: defaults)
        XCTAssertTrue(restored.storageSaver)
        XCTAssertTrue(restored.useQuota)
    }

    /// 0.3.4 and earlier persisted `useQuota` and `saver` inside every prepared
    /// checkpoint. Those keys are gone, and upgrading must not fail to decode a
    /// queue that still carries them — a throw here would drop the user's
    /// in-flight backup on first launch after the update.
    func testLegacyQualityKeysInAPersistedCheckpointStillDecode() throws {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!,
            hash: Data(repeating: 4, count: 20), filename: "IMG.JPG",
            modified: Date(timeIntervalSince1970: 100), byteCount: 123, receipt: nil
        )
        // Re-inject the removed keys rather than hand-writing the JSON, so the
        // fixture cannot drift from whatever the coders actually emit.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(prepared)) as? [String: Any]
        )
        object["useQuota"] = true
        object["saver"] = true
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PreparedUpload.self, from: legacy)
        XCTAssertEqual(decoded, prepared)
    }

    func testCancelledBackgroundTransportAlwaysReleasesItsCaller() async {
        let transferID = UUID()
        let request = URLRequest(url: URL(string: "https://example.com/upload")!)
        let task = Task { () -> Bool in
            do {
                _ = try await BackgroundFileUploadTransport.shared.upload(
                    request,
                    fromFile: URL(fileURLWithPath: "/tmp/does-not-exist"),
                    transferID: transferID,
                    progress: { _, _ in }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        await BackgroundFileUploadTransport.shared.cancel(transferID: transferID)
    }

    func testPendingAssetQueueRestoresAfterRelaunch() async {
        let persistence = MemoryUploadQueuePersistence()
        let firstScript = WorkerScript([])
        let first = UploadQueue(worker: firstScript.worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)

        let secondScript = WorkerScript([])
        let restored = UploadQueue(worker: secondScript.worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("PERSON@gmail.com")

        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items.first?.source, .asset(localIdentifier: "asset-1"))
        XCTAssertEqual(restored.items.first?.state, .queued)
        restored.setNetworkAccess(allowed: true)
        await settle(restored) { restored.items.first?.state == .done }
        XCTAssertEqual(secondScript.calls, 1)
    }

    /// A Live Photo's motion is committed onto its still, so the queue asks for
    /// it only once the still has finished. The motion is recorded but not
    /// counted: it adds to a photo already counted as backed up.
    func testAFinishedLivePhotoQueuesItsMotionWithoutCountingIt() async {
        let queue = makeQueue(WorkerScript([]), maxConcurrent: 1)
        queue.followUpSources = { source in
            guard case .asset(let identifier) = source, identifier == "live-1" else { return [] }
            return [.livePhotoMotion(localIdentifier: identifier)]
        }
        queue.enqueue([.asset(localIdentifier: "live-1"), .asset(localIdentifier: "plain-1")])
        await settle(queue) { queue.items.count == 3 && queue.items.allSatisfy { $0.state == .done } }
        XCTAssertEqual(queue.items.map(\.source), [.asset(localIdentifier: "live-1"),
                                                   .asset(localIdentifier: "plain-1"),
                                                   .livePhotoMotion(localIdentifier: "live-1")])
        XCTAssertEqual(queue.completedSourceCount, 2)
        XCTAssertEqual(queue.completedMotionCount, 1)
    }

    /// A motion row is stored as its asset plus a flag, so builds without motion
    /// rows still read the snapshot; this build restores it as a motion row.
    func testAMotionRowRestoresAsAMotionRow() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue([.livePhotoMotion(localIdentifier: "live-1")], skippingExisting: true)

        XCTAssertEqual(persistence.snapshot?.items.first?.source, .asset("live-1"))
        XCTAssertEqual(persistence.snapshot?.items.first?.motion, true)

        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertEqual(restored.items.first?.source, .livePhotoMotion(localIdentifier: "live-1"))
    }

    /// A photo edited in the Google Photos app also backs up the version that
    /// edit was applied on. Like a motion, it adds to a photo already counted.
    func testAGoogleEditedPhotoQueuesItsEditBaseWithoutCountingIt() async {
        let queue = makeQueue(WorkerScript([]), maxConcurrent: 1)
        queue.followUpSources = { source in
            guard case .asset(let identifier) = source, identifier == "edited-1" else { return [] }
            return [.editBase(localIdentifier: identifier)]
        }
        queue.enqueue([.asset(localIdentifier: "edited-1"), .asset(localIdentifier: "plain-1")])
        await settle(queue) { queue.items.count == 3 && queue.items.allSatisfy { $0.state == .done } }
        XCTAssertEqual(queue.items.last?.source, .editBase(localIdentifier: "edited-1"))
        XCTAssertEqual(queue.completedSourceCount, 2)
        XCTAssertTrue(queue.completedSourceKeys.contains(UploadQueue.editBaseKeyPrefix + "edited-1"))
    }

    /// An edit-base row restores as one, never as a motion row: committing a
    /// photo as a Live Photo's motion would write a bad item to the account.
    func testAnEditBaseRowRestoresAsAnEditBaseRow() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue([.editBase(localIdentifier: "edited-1"), .livePhotoMotion(localIdentifier: "live-1")],
                      skippingExisting: true)

        let stored = persistence.snapshot?.items ?? []
        XCTAssertEqual(stored.map(\.source), [.asset("edited-1"), .asset("live-1")])
        XCTAssertEqual(stored.map(\.editBase), [true, nil])
        XCTAssertEqual(stored.map(\.motion), [nil, true])

        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertEqual(restored.items.map(\.source), [.editBase(localIdentifier: "edited-1"),
                                                      .livePhotoMotion(localIdentifier: "live-1")])
    }

    /// Re-upload queues a backed-up asset again and has its row skip the
    /// duplicate check; an ordinary row still runs it.
    func testReuploadQueuesABackedUpAssetThatSkipsTheDuplicateCheck() async {
        let skipped = SkipRecorder()
        let worker: UploadWorker = { _, _, _, options, _ in
            skipped.record(options.skipsDuplicateCheck)
            return .alreadyBackedUp(mediaKey: "KEY")
        }
        let queue = UploadQueue(worker: worker, maxConcurrent: 1)
        queue.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        await settle(queue) { queue.items.first?.state == .alreadyBackedUp }

        XCTAssertEqual(queue.reupload([.asset(localIdentifier: "asset-1")]), 1)
        await settle(queue) { queue.items.count == 1 && queue.items.first?.state == .alreadyBackedUp }
        XCTAssertEqual(skipped.calls, [false, true])
    }

    /// A re-upload row that outlives the process still skips the check.
    func testAReuploadRowRestoresAsOne() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.reupload([.asset(localIdentifier: "asset-1")])
        XCTAssertEqual(persistence.snapshot?.items.first?.forceUpload, true)

        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertEqual(restored.items.first?.forcesUpload, true)
    }

    func testAMotionCheckpointKeepsItsStillHash() throws {
        let checkpoint = UploadCheckpoint(filePath: "/tmp/staged/IMG.MOV", filename: "IMG.MOV",
                                          modified: Date(timeIntervalSince1970: 100), byteCount: 123,
                                          temporary: true, prepared: nil,
                                          pairedStillHash: Data(repeating: 4, count: 20))
        let decoded = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(decoded.pairedStillHash, Data(repeating: 4, count: 20))
    }

    func testUploadCheckpointRestoresAtTheTransferBoundary() async {
        let persistence = MemoryUploadQueuePersistence()
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 2, count: 20),
            filename: "IMG.JPG", modified: Date(timeIntervalSince1970: 100), byteCount: 123,
            receipt: nil
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/staged/IMG.JPG", filename: "IMG.JPG",
                                          modified: prepared.modified, byteCount: 123,
                                          temporary: true, prepared: prepared,
                                          continuesAfterProcessExit: true)
        let firstWorker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let first = UploadQueue(worker: firstWorker, maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")])

        await settle(first) { persistence.snapshot?.items.first?.checkpoint == checkpoint }
        XCTAssertEqual(persistence.snapshot?.items.first?.checkpoint, checkpoint)

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertEqual(restored.items.first?.checkpoint, checkpoint)
        XCTAssertEqual(restored.retainedStagingURLs, [checkpoint.fileURL])
        first.cancelAll()
    }

    func testFilePersistenceKeepsCompletedKeysOutOfTheRewrittenQueueSnapshot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileUploadQueuePersistence(url: directory.appendingPathComponent("queue.json"))
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        XCTAssertEqual(try persistence.load()?.completedSourceKeys, [])

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertTrue(restored.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true).isEmpty)
    }

    func testCompletedAssetLedgerSurvivesRelaunchAndSkipsTheAsset() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        let accepted = restored.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)

        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(restored.items.isEmpty)
    }

    func testQueueDoesNotCrossGoogleAccounts() {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("first@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")])

        let second = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        second.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        second.activateAccount("second@gmail.com")

        XCTAssertTrue(second.items.isEmpty)
    }

    func testBatchLimitCountsAcceptedItemsAfterDurableDeduplication() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "old")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        let accepted = restored.enqueue(
            [.asset(localIdentifier: "old"), .asset(localIdentifier: "new-1"), .asset(localIdentifier: "new-2")],
            skippingExisting: true,
            limit: 1
        )

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(restored.items.map(\.source), [.asset(localIdentifier: "new-1")])
    }

    func testCancellingAnInFlightItemMarksItCancelledAndFreesTheSlot() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items[0].state == .cancelled && queue.items[1].state == .done }
    }

    func testCancellingAQueuedItemNeverStartsIt() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancel(queue.items[1].id)
        XCTAssertEqual(queue.items[1].state, .cancelled)
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(script.calls, 1)
    }

    func testCancelAllStopsRunningAndQueuedItems() async {
        let script = WorkerScript([.block], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.cancelAll()

        await settle(queue) { queue.items.allSatisfy { $0.state == .cancelled } }
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(script.calls, 1)
    }

    /// The Stop-button freeze: cancelling row by row wrote the whole snapshot
    /// once per row, so a full-library queue paid thousands of synchronous
    /// encode-and-replace passes on the main actor before the UI came back.
    func testStopWritesTheSnapshotOnceNoMatterHowManyRowsItClears() async {
        let persistence = MemoryUploadQueuePersistence()
        let script = WorkerScript([], fallback: .block)
        let queue = UploadQueue(worker: script.worker(), maxConcurrent: 1, persistence: persistence,
                                sleeper: { _ in await Task.yield() })
        queue.activateAccount("person@gmail.com")
        queue.enqueue(sources(200))
        await settle(queue) { queue.items.first?.state.isWorking == true }

        let before = persistence.saveCount
        queue.cancelAll()
        XCTAssertEqual(persistence.saveCount - before, 1)

        // The one in-flight row settles separately, and the queue is empty.
        await settle(queue) { queue.items.isEmpty }
    }

    /// Same shape as Stop: Retry Failed walks the whole queue, so it must not
    /// rewrite the snapshot once per failure either.
    func testRetryAllFailedWritesTheSnapshotOnce() async {
        let persistence = MemoryUploadQueuePersistence()
        let error = GPMCError(kind: .malformed, message: "Google rejected the upload.")
        let script = WorkerScript([], fallback: .fail(error))
        let queue = UploadQueue(worker: script.worker(), maxConcurrent: 1, maxAttempts: 1,
                                persistence: persistence, sleeper: { _ in await Task.yield() })
        queue.activateAccount("person@gmail.com")
        queue.enqueue(sources(20))
        await settle(queue) { queue.failedCount == 20 }
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting")

        let before = persistence.saveCount
        queue.retryAllFailed()
        XCTAssertEqual(persistence.saveCount - before, 1)
        XCTAssertEqual(queue.items.filter { $0.state == .queued }.count, 20)
    }

    /// Stop must not leave the queue in "drop the next cancelled row" mode:
    /// after it settles, a single-row cancel is a durable marker again.
    func testStopDoesNotLeaveLaterSingleCancelsBeingDiscarded() async {
        let script = WorkerScript([], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancelAll()
        await settle(queue) { queue.items.isEmpty }

        queue.enqueue(sources(1))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items.first?.state == .cancelled }
        XCTAssertEqual(queue.items.count, 1)
    }

    func testUserPauseHoldsQueuedItemsUntilResume() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.pauseAfterCurrentUploads()
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items[0].state == .cancelled }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(queue.isUserPaused)
        XCTAssertEqual(queue.items[1].state, .queued)
        XCTAssertEqual(script.calls, 1)

        queue.resumeUserPausedUploads()
        await settle(queue) { queue.items[1].state == .done }
        XCTAssertFalse(queue.isUserPaused)
        XCTAssertEqual(script.calls, 2)
    }

    func testUserPauseSurvivesQueueRestoration() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue(oneSource)
        first.pauseAfterCurrentUploads()

        let script = WorkerScript([])
        let restored = UploadQueue(worker: script.worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        restored.setNetworkAccess(allowed: true)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(restored.isUserPaused)
        XCTAssertEqual(restored.items.first?.state, .queued)
        XCTAssertEqual(script.calls, 0)

        restored.resumeUserPausedUploads()
        await settle(restored) { restored.items.first?.state == .done }
        XCTAssertFalse(restored.isUserPaused)
        XCTAssertEqual(script.calls, 1)
    }

    func testRetryResetsTheAttemptCount() async {
        let error = GPMCError(kind: .malformed, message: "nope")
        let script = WorkerScript([.fail(error)], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        queue.retry(queue.items[0].id)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(queue.items.first?.attempts, 1)
    }

    func testRetryIgnoresItemsThatAlreadySucceeded() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        queue.retry(queue.items[0].id)
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(script.calls, 1)
    }

    func testConcurrencyStaysWithinTheLimit() async {
        let script = WorkerScript([], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 2)
        queue.enqueue(sources(8))
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertLessThanOrEqual(script.peakInFlight, 2)
        XCTAssertEqual(script.calls, 8)
    }

    func testClearFinishedKeepsWorkInProgress() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(1))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.clearFinished()
        XCTAssertEqual(queue.items.count, 1)
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items.first?.state == .cancelled }
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    /// Stop discards the queue. A single-row cancel is a durable "skip this"
    /// marker, but Stop means start over, so a later rescan must be free to
    /// pick these sources up again.
    func testStopDiscardsCancelledRowsSoARescanCanPickThemUp() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.asset(localIdentifier: "asset-1")
        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.cancelAll()
        await settle(queue) { queue.items.isEmpty }
        XCTAssertEqual(queue.enqueue([source], skippingExisting: true).count, 1)
    }

    /// The counterpart: cancelling one row is a decision, and an automatic
    /// rescan must not quietly undo it on the next window.
    func testCancelledRowBlocksReEnqueueUntilItIsCleared() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.asset(localIdentifier: "asset-1")
        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items.first?.state == .cancelled }
        XCTAssertTrue(queue.enqueue([source], skippingExisting: true).isEmpty)

        queue.clearFinished()
        XCTAssertEqual(queue.enqueue([source], skippingExisting: true).count, 1)
    }

    func testACancelledRowSurvivesRestoration() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        first.cancel(first.items[0].id)
        XCTAssertEqual(first.items.first?.state, .cancelled)

        let script = WorkerScript([])
        let restored = UploadQueue(worker: script.worker(), maxConcurrent: 1, persistence: persistence)
        restored.activateAccount("person@gmail.com")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(restored.items.first?.state, .cancelled)
        XCTAssertEqual(script.calls, 0)
    }

    /// A pause has to outlive the queue draining. Clearing it when the last
    /// item finished let the automatic scan enqueue a fresh batch and start
    /// uploading again without the user resuming.
    func testUserPauseSurvivesTheQueueDraining() async {
        let script = WorkerScript([], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(1))
        queue.pauseAfterCurrentUploads()
        await settle(queue) { queue.items.first?.state == .done }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(queue.isIdle)
        XCTAssertTrue(queue.isUserPaused)

        // And a paused queue still refuses to start newly enqueued work.
        queue.enqueue(sources(1))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 1)

        queue.resumeUserPausedUploads()
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertEqual(script.calls, 2)
    }

    /// The change-token commit depends on knowing whether the limit cut the
    /// batch short: advancing past sources that were never examined loses them.
    func testEnqueueReportsWhetherTheLimitTruncatedTheBatch() {
        let queue = makeQueue(WorkerScript([], fallback: .block), maxConcurrent: 1)
        let truncated = queue.enqueueReportingLimit(sources(5), skippingExisting: true, limit: 2)
        XCTAssertEqual(truncated.accepted.count, 2)
        XCTAssertTrue(truncated.reachedLimit)

        let queue2 = makeQueue(WorkerScript([], fallback: .block), maxConcurrent: 1)
        let complete = queue2.enqueueReportingLimit(sources(2), skippingExisting: true, limit: 10)
        XCTAssertEqual(complete.accepted.count, 2)
        XCTAssertFalse(complete.reachedLimit)
    }

    /// The dashboard metric reads this count, so it has to be a count of
    /// distinct sources rather than of completion events: re-verifying a
    /// library that is already in the cloud must leave the number where it was.
    func testCompletedSourceCountCountsDistinctSourcesNotCompletions() async {
        // Upload three, then report every later call as already in the cloud.
        let script = WorkerScript(Array(repeating: .succeed(.uploaded(mediaKey: "ABC")), count: 3),
                                  fallback: .succeed(.alreadyBackedUp(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertEqual(queue.completedSourceCount, 3)

        // What Settings' verify action does: forget the ledger, re-enqueue, and
        // let the worker's hash lookup short-circuit each item.
        queue.reverify(sources(3))
        await settle(queue) { queue.items.allSatisfy { $0.state == .alreadyBackedUp } }
        XCTAssertEqual(queue.completedSourceCount, 3)
    }

    /// Losing an allowed transport has to stop a background PUT too: iOS keeps
    /// the `allowsCellularAccess` the request was created with.
    func testLosingTheAllowedTransportCancelsABackgroundTransferForRequeue() async {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 1, count: 20),
            filename: "photo.jpg", modified: Date(), byteCount: 10,
            receipt: nil
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/photo.jpg", filename: "photo.jpg",
                                          modified: Date(), byteCount: 10, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let worker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            await emit(.state(.uploading(fraction: 0.25)))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let queue = UploadQueue(worker: worker, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.checkpoint == checkpoint }

        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        await settle(queue) { queue.items.first?.state == .queued }
        XCTAssertEqual(queue.items.first?.checkpoint, checkpoint)
    }

    /// A transport failure parks an item in `.failed`, where the enqueue dedup
    /// treats it as a durable handle. Nothing automatic used to release it, so
    /// one network blip stopped those photos being backed up permanently.
    func testRetryableFailuresAreReleasedButPermanentOnesAreNot() async {
        let transport = GPMCError(kind: .transport, message: "Could not reach Google")
        let permanent = GPMCError(kind: .malformed, message: "That item has no file to upload.")
        let script = WorkerScript([.fail(transport), .fail(permanent)], fallback: .fail(transport))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.failedCount == 2 }

        let released = queue.retryRetryableFailures()
        XCTAssertEqual(released, 1)

        await settle(queue) { queue.failedCount == 2 }
        let reasons = queue.items.compactMap { item -> Bool? in
            if case .failed(_, let retryable) = item.state { return retryable }
            return nil
        }
        XCTAssertEqual(reasons.sorted(by: { !$0 && $1 }), [false, true])
    }

    /// Re-check has to defeat two different guards: the completion ledger, and
    /// the finished row left behind by the original upload. Missing either one
    /// makes the button silently do nothing.
    func testReverifyForgetsCompletionsAndEnqueuesThemAgain() async {
        let script = WorkerScript([], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.asset(localIdentifier: "asset-1")
        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(queue.completedSourceCount, 1)

        // Without forgetting, a plain enqueue is correctly a no-op.
        XCTAssertTrue(queue.enqueue([source], skippingExisting: true).isEmpty)

        let result = queue.reverify([source])
        XCTAssertEqual(result.forgotten, 1)
        XCTAssertEqual(result.enqueued, 1)
        await settle(queue) { queue.items.contains { $0.state == .done } }
        XCTAssertEqual(script.calls, 2)
    }

    /// An item still in Google Photos comes back `alreadyBackedUp` from the hash
    /// lookup rather than being uploaded again, and is re-recorded as complete.
    func testReverifyRecordsAnAlreadyBackedUpItemWithoutReuploading() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "ABC"))],
                                  fallback: .succeed(.alreadyBackedUp(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.asset(localIdentifier: "asset-1")
        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state == .done }

        queue.reverify([source])
        await settle(queue) { queue.items.contains { $0.state == .alreadyBackedUp } }
        XCTAssertEqual(queue.completedSourceCount, 1)
    }

    /// A failed row is absent from the ledger, so reverify cannot see it, and as
    /// a tracked row it blocks its own source. Re-check releases it first.
    func testReverifyDoesNotSeeAFailedRowUntilItIsReleased() async {
        let transport = GPMCError(kind: .transport, message: "Could not reach Google")
        let script = WorkerScript([.fail(transport)], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        let source = MediaSource.asset(localIdentifier: "asset-1")
        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.failedCount == 1 }

        // Reverify alone cannot reach it: nothing to forget, nothing enqueued.
        let result = queue.reverify([source])
        XCTAssertEqual(result.forgotten, 0)
        XCTAssertEqual(result.enqueued, 0)

        XCTAssertEqual(queue.retryRetryableFailures(), 1)
        await settle(queue) { queue.items.first?.state == .done }
    }

    /// Raising the limit has to start the extra work immediately rather than
    /// waiting for something else to nudge the queue.
    func testRaisingConcurrencyStartsMoreWorkAtOnce() async {
        let script = WorkerScript([], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(6))
        await settle(queue) { script.peakInFlight == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.peakInFlight, 1)

        queue.setMaxConcurrent(UploadQueue.concurrencyRange.upperBound)
        await settle(queue) { script.peakInFlight == 6 }
        XCTAssertEqual(queue.maxConcurrent, UploadQueue.concurrencyRange.upperBound)
    }

    /// Lowering it must not cancel work already in flight — those uploads have
    /// staged files and, for a background transfer, bytes already on the wire.
    func testLoweringConcurrencyLetsRunningUploadsFinish() async {
        let script = WorkerScript([], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 3)
        queue.enqueue(sources(4))
        await settle(queue) { script.peakInFlight == 3 }

        queue.setMaxConcurrent(1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(queue.maxConcurrent, 1)
        XCTAssertEqual(queue.items.filter { $0.state.isWorking }.count, 3)
    }

    func testConcurrencyIsClampedToTheOfferedRange() {
        let queue = makeQueue(WorkerScript([], fallback: .block), maxConcurrent: 1)
        queue.setMaxConcurrent(0)
        XCTAssertEqual(queue.maxConcurrent, UploadQueue.concurrencyRange.lowerBound)
        queue.setMaxConcurrent(99)
        XCTAssertEqual(queue.maxConcurrent, UploadQueue.concurrencyRange.upperBound)
    }

    func testProgressFractionsAreMonotonicAcrossTheStates() {
        let ordered: [UploadItem.State] = [.hashing(fraction: 0), .hashing(fraction: 1), .checkingDuplicate,
                                           .uploading(fraction: 0), .uploading(fraction: 1), .finalizing, .done]
        let fractions = ordered.compactMap { $0.fraction }
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertNil(UploadItem.State.queued.fraction)
        XCTAssertEqual(UploadItem.State.done.fraction, 1)
    }

    func testPhaseMappingCoversEveryClientPhase() {
        XCTAssertEqual(UploadPhase.hashing(fraction: 0.5).itemState, .hashing(fraction: 0.5))
        XCTAssertEqual(UploadPhase.checkingDuplicate.itemState, .checkingDuplicate)
        XCTAssertEqual(UploadPhase.preparing.itemState, .uploading(fraction: 0))
        XCTAssertEqual(UploadPhase.sending(sent: 50, total: 200).itemState, .uploading(fraction: 0.25))
        XCTAssertEqual(UploadPhase.sending(sent: 1, total: 0).itemState, .uploading(fraction: 0))
        XCTAssertEqual(UploadPhase.finalizing.itemState, .finalizing)
    }

    // MARK: - Incrementally maintained aggregates

    /// One pass over every transition the aggregates have to survive: rows in
    /// flight, a permanent failure, a deferred iCloud row, a cancel, a retry
    /// and a clear. Each of these used to be counted by walking the queue.
    func testAggregatesTrackEveryTransitionTheQueueMakes() async {
        let permanent = GPMCError(kind: .malformed, message: "bad media")
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "A")),
                                   .fail(permanent),
                                   .succeed(.alreadyBackedUp(mediaKey: "B")),
                                   .fail(MediaExporter.Failure.iCloudDownloadRequired)],
                                  fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.setICloudDownloadsAllowed(false)
        assertAggregatesMatchRows(queue)

        queue.enqueue(sources(5))
        assertAggregatesMatchRows(queue)

        // Rows one to four settle; the fifth blocks, so the queue is left with
        // a working row alongside every terminal state at once.
        await settle(queue) { queue.items[4].state.isWorking }
        XCTAssertEqual(queue.items[1].state, .failed(reason: "bad media", retryable: false))
        XCTAssertEqual(queue.items[3].state, .waitingForICloud)
        assertAggregatesMatchRows(queue)

        queue.cancel(queue.items[4].id)
        await settle(queue) { queue.items[4].state == .cancelled }
        assertAggregatesMatchRows(queue)

        queue.retry(queue.items[1].id)
        assertAggregatesMatchRows(queue)

        queue.clearFinished()
        assertAggregatesMatchRows(queue)
    }

    /// `overallFraction` no longer sums every row, only the ones actually in
    /// flight plus a count of the finished ones — so a partly uploaded row has
    /// to still move the bar.
    func testOverallFractionCountsInFlightProgressAndFinishedRows() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "A"))], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(2))
        // The scripted worker reports `.uploading(fraction: 0.5)` and then
        // blocks, so row two is parked halfway with row one already done.
        await settle(queue) { queue.items[1].state == .uploading(fraction: 0.5) }
        XCTAssertEqual(queue.overallFraction, (1 + 0.525) / 2, accuracy: 0.000_001)
        assertAggregatesMatchRows(queue)
    }

    /// The scan for the next row to start resumes where it left off instead of
    /// walking the finished prefix again. Retrying a row the scan has already
    /// passed therefore has to pull that scan back, or the retry would sit in
    /// `.queued` forever while the queue reported itself busy.
    func testRetryingAnEarlyRowStartsItAfterTheRestOfTheQueueDrained() async {
        let script = WorkerScript([.fail(GPMCError(kind: .malformed, message: "bad media"))],
                                  fallback: .succeed(.uploaded(mediaKey: "OK")))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(4))
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(queue.failedCount, 1)

        queue.retry(queue.items[0].id)
        await settle(queue) { queue.items[0].state == .done }
        XCTAssertTrue(queue.isIdle)
        assertAggregatesMatchRows(queue)
    }

    /// Same hazard from the other direction: while the queue is paused the scan
    /// walks past rows it may not start, so resuming has to let it start over.
    func testResumingStartsRowsThePausedScanAlreadyWalkedPast() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.pauseAfterCurrentUploads()
        queue.enqueue(sources(3))
        await settle(queue) { queue.items.allSatisfy { $0.state == .queued } }

        queue.resumeUserPausedUploads()
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        assertAggregatesMatchRows(queue)
    }

    /// Removing rows shifts every offset after them, so the id→offset map has
    /// to be rebuilt or a later event lands on the wrong row.
    func testClearingFinishedRowsKeepsLaterRowsAddressable() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "A"))], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.items[1].state.isWorking }

        queue.clearFinished()
        XCTAssertEqual(queue.items.count, 2)
        let workingID = queue.items[0].id
        let waitingID = queue.items[1].id

        queue.cancel(workingID)
        await settle(queue) { queue.items[0].state == .cancelled }
        // The cancel landed on the row whose id was passed, and the row behind
        // it kept its identity and went on to start in its place.
        XCTAssertEqual(queue.items[1].id, waitingID)
        await settle(queue) { queue.items[1].state.isWorking }
        assertAggregatesMatchRows(queue)
    }
}
