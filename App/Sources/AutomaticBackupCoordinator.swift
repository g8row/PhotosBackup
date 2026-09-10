import BackgroundTasks
import Foundation
import OSLog
import UIKit

/// Owns opportunistic automatic-backup runs in both foreground and system
/// background execution windows. iOS decides when a processing request runs;
/// every invocation submits its successor so the work remains recurring.
@MainActor
final class AutomaticBackupCoordinator: ObservableObject {
    static let taskIdentifier = "com.g8row.photosbackup.background-backup"
    private nonisolated static let logger = Logger(subsystem: "com.g8row.photosbackup", category: "automatic-backup")

    /// How many sources one background enqueue pass may append. This bounds
    /// *memory*, not how much a window uploads — the queue is durable, so
    /// anything a window cannot finish simply waits for the next one. The old
    /// value of 25 meant a window that iOS might only grant once a day could
    /// never let the queue saturate, and so could never advance the change
    /// token either.
    ///
    /// The foreground has no equivalent cap. Paging it meant the queue only
    /// ever showed a slice of the work, so the count the manual buttons
    /// reported was a slice too, and any condition that ended the paging loop
    /// early stranded the rest of the selection off-queue. In the foreground
    /// the whole selection goes in at once and the queue's own concurrency
    /// limit decides how much of it runs.
    private static let backgroundBatchLimit = 250

    /// The earliest start the processing request asks for. An eligibility
    /// date, not a timer: iOS picks the actual moment, usually much later.
    private static let processingRequestDelay: TimeInterval = 15 * 60

    /// The whole Back Up Photos action, scan included, has to fit in the
    /// roughly 30 seconds iOS gives an App Intent. Past that iOS terminates the
    /// process and Shortcuts reports the action as failed. This leaves time to
    /// requeue unfinished work and return the dialog.
    static let shortcutBudget: TimeInterval = 22

    /// When the pending processing request was submitted, so the log can say
    /// how long iOS took to honour it.
    static let lastRequestSubmittedKey = "diagnostics.scheduler.lastSubmittedAt"

    private let photos: PhotosStack
    private let account: PhotosAccount
    private let queue: UploadQueue
    private let preferences: BackupPreferences
    private let albums: PhotoAlbumStore
    private let network: NetworkPolicyMonitor
    private let libraryChanges: PhotoLibraryChangeTracker

    private var registered = false
    private var ranForegroundBackup = false
    private var isForeground = true
    private var shouldRunAfterActivation = false
    private var backgroundOperation: Task<Void, Never>?
    private var foregroundOperation: Task<Void, Never>?
    private var foregroundRunID: UUID?
    /// The scheduling outcome last written to the event log. `updateSchedule`
    /// runs on every background transition, and logging each resubmission would
    /// push the entries a report needs out of the timeline.
    private var loggedScheduleState: String?
#if DEBUG
    @Published private(set) var debugSimulationStatus = "Ready"
    static let lldbSimulationCommand = "e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"\(taskIdentifier)\"]"
    /// The run's OSLog output goes to the system log, not to this screen. On a
    /// simulator this streams it; on a device use Console.app and filter by the
    /// same subsystem.
    static let logStreamCommand = "xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == \"com.g8row.photosbackup\"'"
#endif

    init(photos: PhotosStack,
         account: PhotosAccount,
         queue: UploadQueue,
         preferences: BackupPreferences,
         albums: PhotoAlbumStore,
         network: NetworkPolicyMonitor,
         libraryChanges: PhotoLibraryChangeTracker? = nil) {
        self.photos = photos
        self.account = account
        self.queue = queue
        self.preferences = preferences
        self.albums = albums
        self.network = network
        self.libraryChanges = libraryChanges ?? PhotoLibraryChangeTracker()

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // iOS expects an expiration handler promptly, and the hop to the
            // main actor below can be delayed by whatever it is already doing.
            // Install a handler that works before `begin` runs, then let
            // `begin` replace it with one that can also cancel the operation.
            let window = BackgroundWindow()
            task.expirationHandler = { window.expire() }
            Task { @MainActor [weak self] in self?.begin(task, window: window) }
        }
        if !registered {
            DiagnosticEventLog.shared.record(
                "scheduler",
                "Could not register the background task handler, so iOS cannot start background backups in this build",
                level: .error
            )
        }
    }

    func start() async {
        isForeground = UIApplication.shared.applicationState == .active
        queue.setPreparationGuardArmed(isForeground)
        queue.setICloudDownloadsAllowed(isForeground)
        await photos.start()
        applyNetworkPolicy()
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func networkDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func connectionPreferenceDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func backupConfigurationDidChange() {
        cancelForegroundScan()
        ranForegroundBackup = false
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func accountDidChange() {
        cancelForegroundScan()
        ranForegroundBackup = false
        queue.activateAccount(account.status.email)
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func applicationDidEnterBackground() {
        cancelForegroundScan()
        // Anything still exporting is about to be frozen, not crashed.
        queue.setPreparationGuardArmed(false)
        queue.flushPendingWrites()
        isForeground = false
        queue.setICloudDownloadsAllowed(false)
        shouldRunAfterActivation = true
        updateSchedule()
        let transferring = queue.runningBackgroundTransferCount
        DiagnosticEventLog.shared.record(
            "lifecycle",
            "Left the app with \(queue.activeCount) unfinished, \(transferring) transferring in iOS"
                + (queue.activeCount > transferring ? "; the rest waits for a background window or the next launch" : "")
        )
        DiagnosticEventLog.shared.flush()
    }

    func applicationDidBecomeActive() {
        isForeground = true
        queue.setPreparationGuardArmed(true)
        queue.setICloudDownloadsAllowed(true)
        queue.resumeSystemWork()
        if shouldRunAfterActivation {
            shouldRunAfterActivation = false
            ranForegroundBackup = false
        }
        DiagnosticEventLog.shared.record(
            "lifecycle",
            "Opened the app; \(queue.activeCount) unfinished, \(queue.failedCount) failed"
        )
        runForegroundBackupIfNeeded()
    }

    func applyNetworkPolicy() {
        photos.setCellularUploadsAllowed(preferences.connection == .wifiAndCellular)
        let decision = preferences.connection.decision(for: network.status)
        queue.setNetworkAccess(allowed: decision.allowsUploads, pauseReason: decision.pauseReason)
    }

    func updateSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard registered else {
            noteSchedule("unregistered", "No background window requested: the task handler is not registered", level: .error)
            return
        }
        if let blocker = scheduleBlocker {
            noteSchedule("blocked: \(blocker)", "No background window requested: \(blocker)")
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.processingRequestDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRequestSubmittedKey)
            Self.logger.info("Scheduled the next automatic-backup processing request")
            noteSchedule(
                "scheduled",
                "Requested a background processing window: earliest in 15 minutes, with a network connection. iOS chooses the actual time, often overnight while charging."
            )
        } catch {
            let explanation = Self.explainSchedulingError(error)
            Self.logger.error("Could not schedule automatic backup: \(explanation, privacy: .public)")
            noteSchedule("failed: \(explanation)", "Could not request a background window: \(explanation)", level: .error)
        }
    }

    private func noteSchedule(_ state: String, _ message: String, level: DiagnosticEvent.Level = .info) {
        guard loggedScheduleState != state else { return }
        loggedScheduleState = state
        DiagnosticEventLog.shared.record("scheduler", message, level: level)
    }

    /// `BGTaskScheduler`'s error codes, in terms of what the user can change.
    static func explainSchedulingError(_ error: Error) -> String {
        guard let code = (error as? BGTaskScheduler.Error)?.code else { return error.localizedDescription }
        switch code {
        case .unavailable:
            return "background tasks are unavailable — Background App Refresh is off for this app or the whole device, or this is the Simulator"
        case .tooManyPendingTaskRequests:
            return "iOS already holds too many pending requests from this app"
        case .notPermitted:
            return "this build does not declare the task identifier in its Info.plist"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Why automatic backup cannot run, in the user's terms, or nil when it can.
    /// One source of truth so a refused run can say which condition stopped it
    /// instead of reporting a bare failure.
    var scheduleBlocker: String? { backupBlocker(requiringAutomaticBackup: true) }

    /// A Shortcuts automation is the user asking for a run, like Back Up Now,
    /// so it does not require the Automatic Backup switch. That also lets
    /// someone who wants backups only at a time of their choosing turn the
    /// switch off and schedule the shortcut instead.
    private func backupBlocker(requiringAutomaticBackup: Bool) -> String? {
        if !preferences.completedOnboarding { return "Onboarding is not finished" }
        if requiringAutomaticBackup, !preferences.automaticBackup { return "Automatic Backup is turned off" }
        if preferences.selectedAlbumIDs.isEmpty { return "No albums are selected" }
        if !account.status.isUsable {
            // Before the first unlock after a restart, the Keychain item holding
            // the credential cannot be read, so the account looks disconnected.
            return UIApplication.shared.isProtectedDataAvailable
                ? "No Google account is connected"
                : "No Google account is available — if the iPhone has not been unlocked since it restarted, the saved account cannot be read yet"
        }
        return nil
    }

    private var shouldSchedule: Bool { scheduleBlocker == nil }

    /// The conditions a run starts under. Recorded with every run, because
    /// "why did iOS run it then" and "why did it do so little" are mostly
    /// answered by these.
    func executionContext() -> String {
        var parts: [String] = []
        switch UIApplication.shared.applicationState {
        case .active: parts.append("app open")
        case .inactive: parts.append("app inactive")
        case .background: parts.append("app in background")
        @unknown default: parts.append("app state unknown")
        }
        parts.append("network \(network.status.diagnosticLabel)")
        parts.append(DiagnosticProcessInfo.batteryDescription())
        if ProcessInfo.processInfo.isLowPowerModeEnabled { parts.append("Low Power Mode on") }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal { parts.append("thermal \(DiagnosticProcessInfo.thermal(thermal))") }
        if !UIApplication.shared.isProtectedDataAvailable { parts.append("device locked") }
        return parts.joined(separator: "; ")
    }

    private func runForegroundBackupIfNeeded() {
        guard isForeground,
              !ranForegroundBackup,
              shouldSchedule,
              !queue.isUserPaused,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return }

        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            let completedBefore = self.queue.completedSourceCount
            let run = AutomaticBackupRunHistory.started(.foreground, context: self.executionContext())
            await self.albums.refresh()
            if self.albums.canRead, !Task.isCancelled {
                let sources = await self.albums.sources(for: self.preferences.selectedAlbumIDs)
                if !Task.isCancelled { await self.performForegroundBackup(sources) }
            } else {
                // Access was refused or not decided yet. Release the once-per
                // foreground latch so granting it later still starts a scan.
                self.ranForegroundBackup = false
            }
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
            self.finishForegroundRun(run, completedBefore: completedBefore)
        }
    }

    private func finishForegroundRun(_ run: UUID, completedBefore: Int) {
        let completed = max(0, queue.completedSourceCount - completedBefore)
        let summary: String
        if Task.isCancelled {
            summary = "interrupted when the app left the foreground or the selection changed"
        } else if !albums.canRead {
            summary = "no photo library access (\(DiagnosticReportBuilder.photoAuthorization()))"
        } else {
            summary = "backed up \(completed); \(queue.failedCount) failed; \(queue.activeCount) unfinished"
                + (queue.pauseReason.map { "; paused: \($0)" } ?? "")
        }
        AutomaticBackupRunHistory.finished(
            run,
            success: !Task.isCancelled && albums.canRead && queue.failedCount == 0,
            summary: summary
        )
    }

    /// Hand the whole selection to the queue, then stay alive while it drains so
    /// assets the library gains mid-run are picked up without another tap.
    ///
    /// `manual` runs are the user asking right now, so they are not gated on
    /// `shouldSchedule`. That gate includes "Automatic Backup is turned off" —
    /// which Stop Backup sets — so honouring it here meant a manual run enqueued
    /// one page and then found the loop condition already false, leaving the
    /// rest of the album unqueued until the user tapped again.
    private func performForegroundBackup(_ sources: [MediaSource], manual: Bool = false) async {
        // Same reasoning as the background window: earlier transport failures
        // are invisible to the scan and nothing else releases them.
        queue.retryRetryableFailures()
        while isForeground, !Task.isCancelled, account.status.isUsable,
              manual || shouldSchedule, !isPausedForAnyReason {
            let accepted = queue.enqueue(sources, skippingExisting: true)
            if accepted.isEmpty { return }
            // `hasWorkableItems`, not `activeCount`: rows parked on an iCloud
            // download stay unfinished indefinitely, and waiting on them would
            // hold this loop open long after the queue stopped moving.
            while queue.hasWorkableItems {
                // A pause the queue is honouring must end the loop too,
                // otherwise this polls every 200 ms for as long as the user
                // waits for Wi-Fi or leaves the backup paused.
                if Task.isCancelled || !isForeground || !account.status.isUsable
                    || !(manual || shouldSchedule)
                    || queue.haltReason != nil || isPausedForAnyReason { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Any condition that stops the queue starting new work. Polling past one
    /// of these makes no progress and only keeps the main actor awake.
    private var isPausedForAnyReason: Bool {
        queue.isUserPaused || queue.networkPauseReason != nil || queue.systemPauseReason != nil
    }

    /// The result of a manual "Back Up Now" or "Re-check Backups", so the UI can
    /// say what happened instead of leaving a button that appears to do nothing.
    enum ManualRunOutcome: Equatable {
        case noLibraryAccess
        case noAlbumsSelected
        case nothingToDo
        case started(count: Int)
        case rechecking(count: Int)
    }

    /// "Back Up Now". Queues the entire selection, so the count reported back is
    /// everything this run will attempt rather than the size of a first page.
    func backUpSelectedAlbumsNow() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return noteManual(.manual, .noAlbumsSelected) }
        await albums.refresh()
        guard albums.canRead else { return noteManual(.manual, .noLibraryAccess) }
        let sources = await albums.sources(for: preferences.selectedAlbumIDs)
        // Released before the count is taken, not inside the run, so a retried
        // failure is part of the number the user is shown. A failed row already
        // tracks its source, so `enqueue` cannot count it a second time.
        let released = queue.retryRetryableFailures()
        let accepted = queue.enqueue(sources, skippingExisting: true)
        let total = accepted.count + released
        guard total > 0 else { return noteManual(.manual, .nothingToDo) }
        startForegroundRun(sources, source: .manual)
        return .started(count: total)
    }

    /// "Re-check Backups". Forgets remembered completions for the selection and
    /// re-enqueues it; the worker's hash lookup settles anything still in the
    /// cloud without re-uploading it.
    func reverifySelectedAlbums() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return noteManual(.recheck, .noAlbumsSelected) }
        await albums.refresh()
        guard albums.canRead else { return noteManual(.recheck, .noLibraryAccess) }
        let sources = await albums.sources(for: preferences.selectedAlbumIDs)
        guard !sources.isEmpty else { return noteManual(.recheck, .nothingToDo) }
        // A failed row is not in the completion ledger, so `reverify` cannot see
        // it — and as a tracked row it blocks its own source from being enqueued
        // again. Releasing first is what makes this the "check everything is
        // actually backed up" action the button claims to be.
        let released = queue.retryRetryableFailures()
        let result = queue.reverify(sources)
        let total = result.enqueued + released
        guard total > 0 else { return noteManual(.recheck, .nothingToDo) }
        startForegroundRun(sources, source: .recheck)
        return .rechecking(count: total)
    }

    /// Log a manual run that did not start, with the reason the user was shown.
    private func noteManual(_ source: AutomaticBackupRunSource, _ outcome: ManualRunOutcome) -> ManualRunOutcome {
        let reason: String
        switch outcome {
        case .noAlbumsSelected: reason = "no albums are selected"
        case .noLibraryAccess: reason = "the photo library cannot be read (\(DiagnosticReportBuilder.photoAuthorization()))"
        case .nothingToDo: reason = "everything selected is already backed up or queued"
        case .started, .rechecking: return outcome
        }
        DiagnosticEventLog.shared.record(
            "run",
            "\(source.rawValue) did not start: \(reason)",
            level: outcome == .nothingToDo ? .info : .warning
        )
        return outcome
    }

    /// Take over the foreground loop for a manually started run, so the queue
    /// keeps draining without the user tapping again.
    private func startForegroundRun(_ sources: [MediaSource], source: AutomaticBackupRunSource) {
        cancelForegroundScan()
        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        let completedBefore = queue.completedSourceCount
        let run = AutomaticBackupRunHistory.started(source, context: executionContext())
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performForegroundBackup(sources, manual: true)
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
            self.finishForegroundRun(run, completedBefore: completedBefore)
        }
    }

    private func cancelForegroundScan() {
        foregroundOperation?.cancel()
        foregroundOperation = nil
        foregroundRunID = nil
    }

    private func begin(_ task: BGProcessingTask, window: BackgroundWindow) {
        Self.logger.info("Beginning an iOS background-processing window")
        let submitted = UserDefaults.standard.double(forKey: Self.lastRequestSubmittedKey)
        let waited = submitted > 0
            ? " \(Self.describeInterval(Date().timeIntervalSince1970 - submitted)) after it was requested"
            : ""
        DiagnosticEventLog.shared.record("scheduler", "iOS started a background processing window\(waited)")
        AppSessionTracker.note(.backgroundWork)
        let run = AutomaticBackupRunHistory.started(.backgroundProcessing, context: executionContext())
        let startedAt = Date()
        isForeground = false
        // Log the resubmission below even though its state has not changed:
        // it is what shows the chain of windows continues.
        loggedScheduleState = nil
        updateSchedule()
        queue.setPreparationGuardArmed(true)
        queue.setICloudDownloadsAllowed(false)
        queue.resumeSystemWork()
        backgroundOperation?.cancel()

        let operation = Task { @MainActor [weak self, weak task] in
            guard let self else {
                task?.setTaskCompleted(success: false)
                return
            }
            let report = await self.performBackgroundBackup()
            AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
            self.queue.setPreparationGuardArmed(self.isForeground)
            if !self.isForeground { AppSessionTracker.note(.background) }
            // iOS may suspend the process as soon as the task completes.
            DiagnosticEventLog.shared.flush()
            task?.expirationHandler = nil
            task?.setTaskCompleted(success: report.success)
            Self.logger.info("Background-processing window finished; success=\(report.success)")
            self.backgroundOperation = nil
        }
        backgroundOperation = operation
        let expire: @Sendable () -> Void = { [weak self] in
            let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
            Self.logger.notice("iOS expired the background-processing window; requeuing unfinished uploads")
            DiagnosticEventLog.shared.record(
                "scheduler",
                "iOS ended the background processing window after \(elapsed) s; unfinished work stays queued",
                level: .warning
            )
            operation.cancel()
            Task { @MainActor [weak self] in self?.queue.suspendForBackgroundExpiration() }
        }
        task.expirationHandler = expire
        // iOS may already have expired the window while this hop was queued.
        window.adopt(expire)
    }

    static func describeInterval(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 90 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 90 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) days"
    }

    /// The outcome of one window, with the reason attached. `success` is what
    /// iOS is told; `summary` is what a human reads in Diagnostics and the log.
    struct BackgroundRunReport {
        let success: Bool
        let summary: String
    }

    /// Scan, queue, and wait for what can finish.
    ///
    /// - Parameters:
    ///   - settlementDeadline: stop waiting for uploads at this time even if
    ///     iOS has not ended the window. Unfinished work stays queued.
    ///   - requiresAutomaticBackup: false for runs the user asked for.
    ///   - waitsForUploads: false when the app is open and the foreground
    ///     carries on with the queue anyway.
    private func performBackgroundBackup(settlementDeadline: Date? = nil,
                                         requiresAutomaticBackup: Bool = true,
                                         waitsForUploads: Bool = true) async -> BackgroundRunReport {
        await photos.start()
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()

        // A user pause is durable and must not be bypassed by a scheduled run.
        guard !queue.isUserPaused else {
            return finish(.init(success: true, summary: "Paused by you — no work started"))
        }

        if let blocker = backupBlocker(requiringAutomaticBackup: requiresAutomaticBackup) {
            return finish(.init(success: false, summary: blocker))
        }
        let decision = preferences.connection.decision(for: network.status)
        guard decision.allowsUploads else {
            return finish(.init(success: false,
                                summary: decision.pauseReason ?? "The connection policy does not allow uploads"))
        }

        await albums.refresh()
        guard albums.canRead else {
            return finish(.init(success: false,
                                summary: "No photo library access (\(DiagnosticReportBuilder.photoAuthorization()))"))
        }
        // Release earlier transport/5xx failures before scanning. They are
        // invisible to the scan (the dedup treats a failed row as a durable
        // handle), so without this a network blip parks those items forever.
        let released = queue.retryRetryableFailures()
        let failuresBefore = queue.failedCount
        let scan = libraryChanges.scan(albums: albums,
                                       selectedAlbumIDs: preferences.selectedAlbumIDs,
                                       accountIdentifier: account.status.email)
        // An edited asset already has a completion recorded against its
        // identifier, so the dedup below would drop it. Release those first;
        // the worker's hash lookup still short-circuits anything whose bytes
        // did not actually change.
        if !scan.editedSources.isEmpty {
            queue.forgetCompletedSources(for: scan.editedSources)
        }
        let outcome = queue.enqueueReportingLimit(scan.sources, skippingExisting: true,
                                                  limit: Self.backgroundBatchLimit)
        // Advance the change token once every source in this scan has been
        // durably handed to the queue — accepted now, or already tracked. Only
        // a batch the limit cut short leaves sources unexamined.
        if !outcome.reachedLimit, queue.persistenceWarning == nil { libraryChanges.commit(scan) }

        let backedUpBefore = queue.completedSourceCount
        let settled: Bool
        if waitsForUploads {
            settled = await queue.waitUntilSettled(until: settlementDeadline)
        } else {
            settled = true
        }
        let uploaded = max(0, queue.completedSourceCount - backedUpBefore)
        let newFailures = queue.failedCount - failuresBefore
        var parts: [String] = []
        if released > 0 { parts.append("retried \(released) earlier failure\(released == 1 ? "" : "s")") }
        parts.append("enqueued \(outcome.accepted.count)")
        if waitsForUploads { parts.append("backed up \(uploaded)") }
        // Report the standing failure count, not just this run's delta: a queue
        // that is entirely stuck reads as "nothing happened" otherwise.
        if queue.failedCount > 0 {
            parts.append(newFailures > 0
                ? "\(queue.failedCount) failed (\(newFailures) new)"
                : "\(queue.failedCount) still failing")
        }
        if queue.deferredForICloudCount > 0 {
            parts.append("\(queue.deferredForICloudCount) waiting on iCloud")
        }
        if outcome.reachedLimit { parts.append("more to scan next window") }
        // Say why zero, rather than leaving the reader to guess.
        if outcome.accepted.isEmpty, uploaded == 0, queue.failedCount == 0 {
            parts.append(scan.sources.isEmpty
                ? "no library changes since the last scan"
                : "everything in the selection is already backed up")
        }
        if !waitsForUploads, !queue.isIdle { parts.append("uploads continue in the app") }

        if let halt = queue.haltReason {
            return finish(.init(success: false, summary: "Stopped: \(halt)"))
        }
        if !settled {
            // Expiration, the deadline or a policy pause ends the wait, but the
            // work remains durably queued for the next opportunity. Report
            // success unless the credential halted or new failures appeared,
            // otherwise iOS backs off a window that did everything it could.
            let outOfTime = settlementDeadline.map { Date() >= $0 } == true
            let reason = queue.pauseReason ?? (outOfTime ? "time ran out" : "iOS ended the window")
            let handedOff = queue.runningBackgroundTransferCount
            parts.append("deferred — \(reason)")
            if handedOff > 0 { parts.append("\(handedOff) still transferring in iOS") }
            return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
        }
        return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
    }

    /// The Back Up Photos shortcut. A Shortcuts automation is a real execution
    /// opportunity, but a short one: iOS gives an App Intent about 30 seconds.
    /// Spend it scanning and preparing work, then leave file PUTs with the
    /// background URL session. Unprepared work stays queued for the next
    /// shortcut, processing window, or foreground launch.
    func performShortcutBackup() async -> BackgroundRunReport {
        let startedAt = Date()
        // Two runs over one queue would each requeue the other's work as they
        // ended. The window already scans for new photos.
        if backgroundOperation != nil {
            DiagnosticEventLog.shared.record(
                "shortcut",
                "Back Up Photos ran during a background window, so it left the work to that window"
            )
            return BackgroundRunReport(
                success: true,
                summary: "A background backup is already running and will include new photos."
            )
        }
        let appActive = UIApplication.shared.applicationState == .active
        let run = AutomaticBackupRunHistory.started(.shortcut, context: executionContext())
        if !appActive {
            isForeground = false
            AppSessionTracker.note(.backgroundWork)
            queue.setPreparationGuardArmed(true)
            queue.setICloudDownloadsAllowed(false)
        }
        queue.resumeSystemWork()
        updateSchedule()
        let report = await performBackgroundBackup(
            settlementDeadline: startedAt.addingTimeInterval(Self.shortcutBudget),
            requiresAutomaticBackup: false,
            waitsForUploads: !appActive
        )
        // In the background the process is suspended once the action returns.
        // Requeue whatever has not reached iOS's transfer service, so it resumes
        // at the next opportunity instead of freezing mid-export. With the app
        // open, the foreground simply carries on.
        if UIApplication.shared.applicationState != .active {
            if !queue.isIdle { queue.suspendForBackgroundExpiration() }
            queue.setPreparationGuardArmed(false)
            AppSessionTracker.note(.background)
        }
        AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
        DiagnosticEventLog.shared.flush()
        return report
    }

    private func finish(_ report: BackgroundRunReport) -> BackgroundRunReport {
        if report.success {
            Self.logger.info("Automatic backup run: \(report.summary, privacy: .public)")
        } else {
            Self.logger.notice("Automatic backup run did not complete: \(report.summary, privacy: .public)")
        }
        return report
    }

    func diagnosticSnapshot() async -> AutomaticBackupDiagnosticSnapshot {
        let requests: [BGTaskRequest] = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning: $0) }
        }
        let summaries = requests.map { request in
            let processing = request as? BGProcessingTaskRequest
            return AutomaticBackupDiagnosticSnapshot.Request(
                identifier: request.identifier,
                kind: processing == nil ? "app-refresh" : "processing",
                earliestBeginDate: request.earliestBeginDate,
                requiresNetwork: processing?.requiresNetworkConnectivity,
                requiresPower: processing?.requiresExternalPower
            )
        }
        let submitted = UserDefaults.standard.double(forKey: Self.lastRequestSubmittedKey)
        return AutomaticBackupDiagnosticSnapshot(
            handlerRegistered: registered,
            appConsideredForeground: isForeground,
            foregroundOperationActive: foregroundOperation != nil,
            backgroundOperationActive: backgroundOperation != nil,
            scheduleBlocker: scheduleBlocker,
            networkStatus: network.status.diagnosticLabel,
            pendingRequests: summaries,
            lastRequestSubmittedAt: submitted > 0 ? Date(timeIntervalSince1970: submitted) : nil
        )
    }

    /// Called from the background URL-session delegate before iOS receives its
    /// relaunch completion handler. It restores the queue and lets completed
    /// PUT receipts reach the small commit RPC.
    func handleBackgroundURLSessionEvents() async {
        let run = AutomaticBackupRunHistory.started(.backgroundTransfer, context: executionContext())
        isForeground = UIApplication.shared.applicationState == .active
        if !isForeground {
            AppSessionTracker.note(.backgroundWork)
            // Filter before restoration so `activateAccount`'s internal pump
            // cannot start fresh exports, and pause network so nothing pumps
            // before the real policy is applied below.
            queue.noteBackgroundTransferCompletionsPending()
            queue.setNetworkAccess(allowed: false, pauseReason: "Restoring background transfers")
        }
        await photos.start()
        let completedBefore = queue.completedSourceCount
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()
        isForeground = UIApplication.shared.applicationState == .active
        queue.setICloudDownloadsAllowed(isForeground)
        if isForeground { queue.resumeSystemWork() }
        else { queue.resumeBackgroundTransferCompletions() }
        await queue.waitUntilBackgroundTransfersHandled()
        isForeground = UIApplication.shared.applicationState == .active
        if isForeground { queue.resumeSystemWork() }
        else {
            queue.finishBackgroundTransferCompletions()
            AppSessionTracker.note(.background)
        }
        let confirmed = max(0, queue.completedSourceCount - completedBefore)
        AutomaticBackupRunHistory.finished(
            run,
            success: queue.haltReason == nil && queue.failedCount == 0,
            summary: "confirmed \(confirmed) with Google; \(queue.failedCount) failed; \(queue.activeCount) unfinished"
                + (queue.haltReason.map { "; stopped: \($0)" } ?? "")
        )
    }

#if DEBUG
    func simulateRun() {
        guard backgroundOperation == nil else { return }
        debugSimulationStatus = "Running…"
        let run = AutomaticBackupRunHistory.started(.debugSimulation, context: executionContext())
        queue.setICloudDownloadsAllowed(false)
        backgroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.performBackgroundBackup()
            self.debugSimulationStatus = report.summary
            AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
            if self.isForeground { self.queue.setICloudDownloadsAllowed(true) }
            self.backgroundOperation = nil
        }
    }
#endif
}

/// Bridges the gap between a `BGProcessingTask` arriving on a system queue and
/// the coordinator taking it over on the main actor. An expiration that lands
/// inside that gap is remembered and replayed to the real handler.
final class BackgroundWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var handler: (@Sendable () -> Void)?

    func expire() {
        lock.lock()
        expired = true
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func adopt(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        let alreadyExpired = expired
        lock.unlock()
        if alreadyExpired { handler() }
    }
}
