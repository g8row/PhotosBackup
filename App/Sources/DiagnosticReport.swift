import BackgroundTasks
import Foundation
import Photos
import UIKit

struct BackgroundTransferDiagnosticSnapshot: Sendable {
    let taskStates: [String: Int]
    let bytesSent: Int64
    let bytesExpected: Int64
    let storedResultCount: Int
    let storedResultBytes: Int64
    let waiterCount: Int
    let startingCount: Int
    let progressTrackedCount: Int
    let awaitingRelaunchDrain: Bool
}

struct AutomaticBackupDiagnosticSnapshot: Sendable {
    struct Request: Sendable {
        let identifier: String
        let kind: String
        let earliestBeginDate: Date?
        let requiresNetwork: Bool?
        let requiresPower: Bool?
    }

    let handlerRegistered: Bool
    let appConsideredForeground: Bool
    let foregroundOperationActive: Bool
    let backgroundOperationActive: Bool
    let scheduleBlocker: String?
    let networkStatus: String
    let pendingRequests: [Request]
    let lastRequestSubmittedAt: Date?
}

struct DiagnosticReport: Sendable {
    let url: URL
    let text: String
    /// Plain-language observations shown at the top of the report and in the
    /// app, so a user can often fix the problem without filing anything.
    let findings: [String]
}

@MainActor
enum DiagnosticReportBuilder {
    static func create(
        log: ProbeLog,
        account: PhotosAccount,
        queue: UploadQueue,
        preferences: BackupPreferences,
        albums: PhotoAlbumStore,
        automaticBackup: AutomaticBackupCoordinator
    ) async throws -> DiagnosticReport {
        async let storageTask = AppStorageUsage.measure()
        async let transferTask = BackgroundFileUploadTransport.shared.diagnosticSnapshot()
        async let schedulerTask = automaticBackup.diagnosticSnapshot()
        let (storage, transfers, scheduler) = await (storageTask, transferTask, schedulerTask)

        let generatedAt = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let runs = AutomaticBackupRunHistory.recent()
        let crashes = CrashDiagnosticsCollector.shared.snapshot()
        let previousSession = AppSessionTracker.previousSessionOutcome()
        let events = DiagnosticEventLog.shared.snapshot()
        let capacity = capacitySnapshot()
        let findings = self.findings(
            account: account, queue: queue, preferences: preferences, albums: albums,
            scheduler: scheduler, runs: runs, crashes: crashes,
            previousSession: previousSession, availableCapacity: capacity.available,
            now: generatedAt
        )

        var lines: [String] = []
        func section(_ title: String) { lines.append("\n## \(title)") }
        func field(_ name: String, _ value: Any?) {
            lines.append("\(name): \(value.map(String.init(describing:)) ?? "unavailable")")
        }
        func stamp(_ date: Date?) -> String? { date.map(formatter.string(from:)) }
        func ago(_ date: Date) -> String {
            AutomaticBackupCoordinator.describeInterval(generatedAt.timeIntervalSince(date)) + " ago"
        }

        lines.append("Photos Backup diagnostic report")
        lines.append("Generated: \(formatter.string(from: generatedAt))")
        lines.append("Report ID: \(UUID().uuidString)")
        lines.append("Privacy: credentials, account addresses, photo identifiers, filenames, media, and request URLs are excluded or redacted.")

        section("What stands out")
        for finding in findings { lines.append("- \(finding)") }

        section("App and device")
        field("App version", DiagnosticProcessInfo.appVersion)
        field("Bundle identifier", Bundle.main.bundleIdentifier)
        field("Build configuration", buildConfiguration)
        field("iOS", UIDevice.current.systemVersion)
        field("Hardware", hardwareIdentifier())
        field("App state", appState(UIApplication.shared.applicationState))
        field("Protected data available", UIApplication.shared.isProtectedDataAvailable)
        field("Background App Refresh", DiagnosticProcessInfo.backgroundRefresh(UIApplication.shared.backgroundRefreshStatus))
        field("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled)
        field("Thermal state", DiagnosticProcessInfo.thermal(ProcessInfo.processInfo.thermalState))
        field("Battery", DiagnosticProcessInfo.batteryDescription())
        field("Memory", DiagnosticProcessInfo.memoryDescription())
        field("Physical memory", DiagnosticProcessInfo.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))
        field("System uptime", AutomaticBackupCoordinator.describeInterval(ProcessInfo.processInfo.systemUptime))
        field("Locale", Locale.current.identifier)
        field("Time zone GMT offset seconds", TimeZone.current.secondsFromGMT())
        field("Volume total", DiagnosticProcessInfo.bytes(capacity.total))
        field("Volume available for important use", DiagnosticProcessInfo.bytes(capacity.available))

        section("Permissions and configuration")
        field("Photo library access", photoAuthorization())
        field("Onboarding complete", preferences.completedOnboarding)
        field("Account state", accountState(account.status))
        field("Credential persistence warning", redacted(account.persistenceWarning))
        field("Automatic Backup", preferences.automaticBackup)
        field("Selected album count", preferences.selectedAlbumIDs.count)
        field("Loaded album count", albums.albums.count)
        field("Connection policy", preferences.connection.rawValue)
        field("Observed network", scheduler.networkStatus)
        field("Simultaneous uploads", preferences.concurrentUploads)
        field("Storage Saver", preferences.storageSaver)
        field("Count against quota", preferences.useQuota)
        let profile = GPMCClient.commitProfile(useQuota: preferences.useQuota, saver: preferences.storageSaver)
        field("Commit profile", "device \(profile.model), quality code \(profile.quality) (\(preferences.storageSaver ? "Storage Saver" : "original"))")

        section("Scheduler")
        field("Handler registered", scheduler.handlerRegistered)
        field("Coordinator foreground", scheduler.appConsideredForeground)
        field("Foreground operation active", scheduler.foregroundOperationActive)
        field("Background operation active", scheduler.backgroundOperationActive)
        field("Schedule blocker", redacted(scheduler.scheduleBlocker))
        field("Last request submitted", scheduler.lastRequestSubmittedAt.map { "\(formatter.string(from: $0)) (\(ago($0)))" })
        field("Pending request count", scheduler.pendingRequests.count)
        for (index, request) in scheduler.pendingRequests.enumerated() {
            lines.append("Request \(index + 1): kind=\(request.kind); identifier=\(request.identifier); earliest=\(stamp(request.earliestBeginDate) ?? "none"); network=\(optionalBool(request.requiresNetwork)); power=\(optionalBool(request.requiresPower))")
        }
        let weekAgo = generatedAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let windows = runs.filter { $0.source == .backgroundProcessing }
        field("Background processing windows in the last 7 days", windows.filter { $0.startedAt >= weekAgo }.count)
        field("Last background processing window", windows.first.map { "\(formatter.string(from: $0.startedAt)) (\(ago($0.startedAt)))" } ?? "none recorded")
        field("Last Shortcuts run", runs.first { $0.source == .shortcut }.map { "\(formatter.string(from: $0.startedAt)) (\(ago($0.startedAt)))" } ?? "none recorded")

        section("Recent runs (newest first, maximum \(AutomaticBackupRunHistory.limit))")
        if runs.isEmpty { lines.append("None recorded.") }
        for run in runs {
            let outcome = run.success.map { $0 ? "completed" : "did not complete" } ?? "no finish recorded"
            let duration = run.duration.map { " in \(AutomaticBackupCoordinator.describeInterval($0))" } ?? ""
            lines.append("- \(formatter.string(from: run.startedAt)) · \(run.source.rawValue) · \(outcome)\(duration)")
            if let context = run.context { lines.append("    conditions: \(context)") }
            if let summary = run.summary { lines.append("    result: \(summary)") }
        }

        section("Crashes and terminations")
        field("Previous session", previousSession ?? "ended normally")
        field("Process exits reported by iOS", crashes.exitSummary.map { summary in
            summary + (crashes.exitPeriodEnd.map { " (period ending \(formatter.string(from: $0)))" } ?? "")
        } ?? "none received")
        if crashes.diagnostics.isEmpty {
            lines.append("No crash reports received. iOS delivers them a day or so later, and only when Share With App Developers is on (Settings → Privacy & Security → Analytics & Improvements).")
        }
        for diagnostic in crashes.diagnostics.reversed() {
            lines.append("- \(formatter.string(from: diagnostic.periodEnd)) · \(diagnostic.kind) · \(diagnostic.appVersion) · \(diagnostic.osVersion ?? "iOS unknown")")
            lines.append("    \(diagnostic.detail)")
            if let uuid = diagnostic.appBinaryUUID { lines.append("    app binary UUID: \(uuid)") }
            for frame in diagnostic.frames { lines.append("    \(frame)") }
        }

        section("Upload queue")
        field("Rows", queue.items.count)
        field("State counts", queueStateCounts(queue.items))
        field("Unfinished", queue.activeCount)
        field("Failed", queue.failedCount)
        field("Waiting for iCloud", queue.deferredForICloudCount)
        field("Rows skipped after stopping the app", queue.items.filter { $0.interruptedPreparations >= UploadQueue.interruptedPreparationLimit }.count)
        field("Completed source records", queue.completedSourceCount)
        field("Maximum concurrency", queue.maxConcurrent)
        field("Running now", queue.runningCount)
        field("Running in iOS background transfers", queue.runningBackgroundTransferCount)
        field("Maximum attempts", queue.maxAttempts)
        field("User paused", queue.isUserPaused)
        field("Pause reason", redacted(queue.pauseReason))
        field("Halt reason", redacted(queue.haltReason))
        field("Persistence warning", redacted(queue.persistenceWarning))
        field("Failures this process", queue.failureCount)
        field("Recent failure details", queue.recentFailures.count)
        for failure in queue.recentFailures {
            lines.append("- \(formatter.string(from: failure.date)); code=\(failure.statusCode.map(String.init) ?? "none"); reason=\(DiagnosticRedactor.redact(failure.reason))")
        }

        section("Background URL session")
        field("Session identifier", BackgroundFileUploadTransport.sessionIdentifier)
        field("Task states", transfers.taskStates.isEmpty ? "no tasks" : transfers.taskStates.keys.sorted().map { "\($0)=\(transfers.taskStates[$0]!)" }.joined(separator: ", "))
        field("Bytes sent", DiagnosticProcessInfo.bytes(transfers.bytesSent))
        field("Bytes expected", DiagnosticProcessInfo.bytes(transfers.bytesExpected))
        field("Stored result count", transfers.storedResultCount)
        field("Stored result bytes", DiagnosticProcessInfo.bytes(transfers.storedResultBytes))
        field("Waiting callers", transfers.waiterCount)
        field("Transfers being created", transfers.startingCount)
        field("Transfers tracked for progress", transfers.progressTrackedCount)
        field("Awaiting relaunch drain", transfers.awaitingRelaunchDrain)

        section("Storage")
        field("Pending upload copies", DiagnosticProcessInfo.bytes(storage.stagedUploads))
        field("Backup records", DiagnosticProcessInfo.bytes(storage.backupRecords))
        field("Transfer receipts", DiagnosticProcessInfo.bytes(storage.transferResults))
        field("System caches", DiagnosticProcessInfo.bytes(storage.caches))
        field("App-managed total", DiagnosticProcessInfo.bytes(storage.appManaged))

        section("Connection probe")
        for step in log.steps {
            lines.append("- \(step.title): \(probeState(step.state)); \(DiagnosticRedactor.redact(step.detail))")
        }

        section("Event timeline (oldest first)")
        let warnings = events.filter { $0.level == .warning }.count
        let errors = events.filter { $0.level == .error }.count
        field("Entries", "\(events.count) (\(errors) errors, \(warnings) warnings); at most \(DiagnosticEventLog.defaultLimit), from the last 14 days, with routine entries dropped first")
        for event in events {
            lines.append(event.line(formatter))
        }

        lines.append("\nEnd of report")
        let text = lines.joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosBackupDiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        let url = directory.appendingPathComponent("PhotosBackup-Diagnostics-\(Int(generatedAt.timeIntervalSince1970)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        DiagnosticEventLog.shared.record("support", "Created a diagnostic report")
        return DiagnosticReport(url: url, text: text, findings: findings)
    }

    /// The conditions most likely to explain "backup is not happening", in the
    /// order a user can act on them.
    static func findings(
        account: PhotosAccount,
        queue: UploadQueue,
        preferences: BackupPreferences,
        albums: PhotoAlbumStore,
        scheduler: AutomaticBackupDiagnosticSnapshot,
        runs: [AutomaticBackupRunRecord],
        crashes: CrashDiagnosticsSnapshot,
        previousSession: String?,
        availableCapacity: Int64?,
        now: Date
    ) -> [String] {
        var notes: [String] = []
        if let previousSession { notes.append(previousSession) }
        if !crashes.diagnostics.isEmpty {
            notes.append("iOS has reported \(crashes.diagnostics.count) crash or performance problem\(crashes.diagnostics.count == 1 ? "" : "s"); the details are under Crashes and Terminations.")
        }
        if UIApplication.shared.backgroundRefreshStatus != .available {
            notes.append("Background App Refresh is off, so iOS will not start background backups. Turn it on in Settings → General → Background App Refresh.")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            notes.append("Low Power Mode is on; iOS runs few or no background tasks while it is.")
        }
        if let halt = queue.haltReason {
            notes.append("The queue is stopped: \(halt)")
        } else if let pause = queue.pauseReason {
            notes.append("Uploads are paused: \(pause)")
        }
        if let blocker = scheduler.scheduleBlocker {
            notes.append("Automatic backup is not scheduled: \(blocker).")
        } else if scheduler.handlerRegistered, scheduler.pendingRequests.isEmpty, !scheduler.backgroundOperationActive {
            notes.append("Automatic Backup is on but no background window is requested at the moment. A new request is made each time the app goes to the background.")
        }
        if scheduler.scheduleBlocker == nil {
            if let window = runs.first(where: { $0.source == .backgroundProcessing }) {
                let age = now.timeIntervalSince(window.startedAt)
                if age > 3 * 24 * 60 * 60 {
                    notes.append("iOS last granted a background processing window \(AutomaticBackupCoordinator.describeInterval(age)) ago. iOS gives fewer windows to apps that are opened rarely; a Shortcuts automation adds more chances.")
                }
            } else {
                notes.append("No background processing window has been recorded yet. iOS decides when these run, typically overnight while charging on Wi-Fi.")
            }
        }
        if queue.failedCount > 0 {
            notes.append("\(queue.failedCount) item\(queue.failedCount == 1 ? "" : "s") failed; Google's reasons are listed under Upload Queue.")
        }
        let skipped = queue.items.filter { $0.interruptedPreparations >= UploadQueue.interruptedPreparationLimit }.count
        if skipped > 0 {
            notes.append("\(skipped) item\(skipped == 1 ? " was" : "s were") skipped because the app closed unexpectedly while preparing \(skipped == 1 ? "it" : "them") more than once.")
        }
        if queue.deferredForICloudCount > 0 {
            notes.append("\(queue.deferredForICloudCount) item\(queue.deferredForICloudCount == 1 ? " is" : "s are") only in iCloud and continue only while the app is open.")
        }
        if let warning = queue.persistenceWarning { notes.append(warning) }
        if let warning = account.persistenceWarning { notes.append("The Google account is not saved in the Keychain: \(warning)") }
        if albums.isLimited {
            notes.append("Photo access is limited to selected photos, so albums contain only what was shared with the app.")
        }
        if let availableCapacity, availableCapacity < 2_000_000_000 {
            notes.append("Less than 2 GB of storage is free; each upload needs room for a temporary copy.")
        }
        if notes.isEmpty { notes.append("Nothing unusual was detected.") }
        return notes.map { DiagnosticRedactor.redact($0) }
    }

    static func photoAuthorization() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "full"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    private static func redacted(_ value: String?) -> String? {
        value.map { DiagnosticRedactor.redact($0) }
    }

    private static var buildConfiguration: String {
#if DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    private static func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "n/a"
    }

    private static func hardwareIdentifier() -> String {
        var value = utsname()
        uname(&value)
        return withUnsafePointer(to: &value.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func capacitySnapshot() -> (total: Int64?, available: Int64?) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return (
            values?.volumeTotalCapacity.map(Int64.init),
            values?.volumeAvailableCapacityForImportantUsage
        )
    }

    private static func accountState(_ status: PhotosAccount.Status) -> String {
        switch status {
        case .loading: return "loading"
        case .disconnected: return "disconnected"
        case .connected(_, let since): return "connected since \(ISO8601DateFormatter().string(from: since))"
        case .rejected(_, let reason): return "rejected: \(DiagnosticRedactor.redact(reason))"
        }
    }

    private static func appState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func queueStateCounts(_ items: [UploadItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts[queueState(item.state), default: 0] += 1 }
        return counts.isEmpty ? "empty" : counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: ", ")
    }

    private static func queueState(_ state: UploadItem.State) -> String {
        switch state {
        case .queued: return "queued"
        case .waitingToRetry: return "retry-delay"
        case .waitingForICloud: return "iCloud"
        case .exporting: return "exporting"
        case .hashing: return "hashing"
        case .checkingDuplicate: return "duplicate-check"
        case .uploading: return "uploading"
        case .finalizing: return "finalizing"
        case .alreadyBackedUp: return "already-backed-up"
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    private static func probeState(_ state: ProbeStep.State) -> String {
        switch state {
        case .pending: return "pending"
        case .running: return "running"
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }
}

extension DiagnosticEvent {
    /// One line of the report's timeline, and of "Copy All" in the app.
    func line(_ formatter: ISO8601DateFormatter) -> String {
        var text = "\(formatter.string(from: date)) [\(level.rawValue.uppercased())] [\(category)] \(message)"
        if occurrences > 1 {
            text += " (×\(occurrences)" + (firstDate.map { " since \(formatter.string(from: $0))" } ?? "") + ")"
        }
        return text
    }
}
