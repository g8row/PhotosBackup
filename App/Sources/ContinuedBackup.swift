import BackgroundTasks
import Foundation

/// The decisions behind a continued backup, kept apart from `BGTaskScheduler`
/// so they can be tested.
enum ContinuedBackupPolicy {
    /// The Info.plist wildcard a continued-backup identifier is built from.
    static let identifierMarker = ".continued-backup.*"

    /// Uploads that run at once while the app is in the background. Each one
    /// stages and hashes a full copy, and iOS ends a background process whose
    /// memory or CPU it needs back, whatever the user chose for the open app.
    static let backgroundConcurrencyLimit = 2

    /// How long a submitted request may go without iOS starting it before the
    /// app stops counting on it.
    static let launchTimeout: TimeInterval = 15

    /// How long a transient network pause may last before ending the Live
    /// Activity, so a brief Wi-Fi blip does not kill the continuation for the
    /// rest of the background run.
    static let pauseGrace: TimeInterval = 30

    /// Whether the queue can move on its own. A rate-limit wait ends by itself,
    /// so it keeps the task; a pause that needs the user, a connection, the
    /// account or a new iOS window does not.
    static func shouldContinue(hasWorkableItems: Bool, userPaused: Bool, halted: Bool,
                               networkPaused: Bool, systemPaused: Bool,
                               powerPaused: Bool = false,
                               dailyLimitPaused: Bool = false) -> Bool {
        hasWorkableItems && !userPaused && !halted && !networkPaused && !systemPaused && !powerPaused && !dailyLimitPaused
    }

    /// The identifier prefixes to submit under, best first. iOS wants the
    /// running bundle ID at the front of a continued-processing identifier, and
    /// the identifier has to match an Info.plist wildcard. SideStore renames the
    /// bundle when it signs the app (`com.example.app` → `com.example.app.TEAMID`)
    /// but leaves the plist as built, so the build-time entry is tried when no
    /// entry covers the running bundle ID. Do not add a broad `<bundle ID>.*`
    /// entry to cover it: it also covers the processing task's identifier, and
    /// with it iOS refused to register that task's handler (seen on device,
    /// 2026-09-19).
    static func identifierPrefixes(bundleIdentifier: String?, permitted: [String]) -> [String] {
        let wildcards = permitted.filter { $0.hasSuffix(".*") }.map { String($0.dropLast()) }
        var prefixes: [String] = []
        if let bundleIdentifier {
            let own = bundleIdentifier + ".continued-backup."
            if wildcards.contains(where: { own.hasPrefix($0) }) { prefixes.append(own) }
        }
        for wildcard in wildcards where wildcard.hasSuffix(identifierMarker.dropLast()) && !prefixes.contains(wildcard) {
            prefixes.append(wildcard)
        }
        return prefixes
    }
}

/// What the Live Activity of a continued backup shows.
struct ContinuedBackupProgress: Equatable {
    let completed: Int64
    let total: Int64

    init(settledSinceStart: Int, unfinished: Int) {
        completed = Int64(max(0, settledSinceStart))
        total = completed + Int64(max(0, unfinished))
    }

    func subtitle(waitingFor reason: String?) -> String {
        reason ?? "\(completed.formatted()) of \(total.formatted()) done"
    }

    /// Units iOS sees per queue item, so a heartbeat can move the reported
    /// progress while an item is in flight without reaching the next one.
    static let unitsPerItem: Int64 = 1000

    /// The completed units to report next. iOS expires a continued task whose
    /// progress has not moved for about 30 s (Apple DTS, developer forums
    /// thread 805554), and one queue item can take longer than that — a slow
    /// upload, a retry, a wait on Google's rate limit. Apple's advice is to
    /// report progress artificially in that case, so a heartbeat adds one unit,
    /// always staying inside the item in flight; real progress jumps ahead.
    func nextReported(after reported: Int64, heartbeat: Bool) -> Int64 {
        let floor = completed * Self.unitsPerItem
        let ceiling = max(floor, min((completed + 1) * Self.unitsPerItem - 1, total * Self.unitsPerItem))
        let next = max(reported, floor) + (heartbeat ? 1 : 0)
        return min(max(next, floor), ceiling)
    }
}

// The API arrived with the iOS 26 SDK (Swift 6.2, Xcode 26); older toolchains
// build without it, and the app behaves as it did before.
#if compiler(>=6.2)
/// Keeps the upload queue running after the app leaves the foreground, through
/// an iOS 26 continued-processing task. iOS shows its progress in a Live
/// Activity, where it can also be cancelled. Without one, iOS suspends the app
/// seconds after it leaves the foreground, and only uploads already handed to
/// its background transfer service carry on.
///
/// iOS accepts the request only while the app is in the foreground, so the
/// coordinator starts one whenever the app is open with work queued.
@available(iOS 26.0, *)
@MainActor
final class ContinuedBackupSession {
    static let title = "Backing up to Google Photos"

    /// iOS ended the task early: cancelled in the Live Activity, or the system
    /// needed the resources. Runs before iOS is told the task is over, which
    /// may suspend the app at once.
    var onExpired: (() -> Void)?
    /// iOS started the task. Usually at once, while the app is still open.
    var onStarted: (() -> Void)?

    /// Submitted, or running.
    var isActive: Bool { identifier != nil }
    /// iOS has started the task, so the app keeps running when backgrounded.
    var isRunning: Bool { task != nil }
    /// Submitted, but iOS has not started it for longer than it should take.
    var isOverdue: Bool {
        guard isActive, !isRunning, let submittedAt else { return false }
        return Date().timeIntervalSince(submittedAt) > ContinuedBackupPolicy.launchTimeout
    }
    private var identifier: String?
    private var submittedAt: Date?
    private var task: BGContinuedProcessingTask?
    private var lastSubtitle: String?
    private(set) var settledAtStart = 0
    private var latest = ContinuedBackupProgress(settledSinceStart: 0, unfinished: 0)
    private var reported: Int64 = 0
    private var heartbeat: Task<Void, Never>?
    /// When an item last finished, for the log when iOS ends the task.
    private(set) var lastItemFinishedAt: Date?
    static let heartbeatInterval: UInt64 = 5_000_000_000

    func start(prefix: String, settledNow: Int, subtitle: String) throws {
        let identifier = prefix + UUID().uuidString
        // Registration of a continued-processing identifier is allowed after
        // launch; each task gets its own, since registering one twice is fatal.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Same gap as the processing window: install a handler before the
            // hop to the main actor, and replay an expiry that lands inside it.
            let window = BackgroundWindow()
            task.expirationHandler = { window.expire() }
            Task { @MainActor [weak self] in
                guard let self, self.identifier == identifier else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.adopt(task, window: window)
            }
        }
        guard registered else { throw BGTaskScheduler.Error(.notPermitted) }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: Self.title, subtitle: subtitle)
        // Run now or not at all: a queued request would start whenever iOS
        // chose, perhaps after the app is no longer holding any work.
        request.strategy = .fail
        self.identifier = identifier
        submittedAt = Date()
        settledAtStart = settledNow
        latest = ContinuedBackupProgress(settledSinceStart: 0, unfinished: 0)
        reported = 0
        lastItemFinishedAt = nil
        lastSubtitle = subtitle
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            self.identifier = nil
            throw error
        }
    }

    func update(_ progress: ContinuedBackupProgress, subtitle: String) {
        if progress.completed > latest.completed { lastItemFinishedAt = Date() }
        latest = progress
        report(heartbeat: false)
        guard let task, subtitle != lastSubtitle else { return }
        lastSubtitle = subtitle
        task.updateTitle(Self.title, subtitle: subtitle)
    }

    /// End the task. Always as a success: the flag tells iOS what to do with
    /// the Live Activity, not whether the backup finished (Apple DTS, developer
    /// forums thread 808756). False leaves a "Task Failed" card on screen until
    /// iOS clears it, and unfinished work stays queued either way. When iOS
    /// itself ends the task, it shows that card before the app hears about it.
    func finish() {
        heartbeat?.cancel()
        heartbeat = nil
        let task = self.task
        self.task = nil
        identifier = nil
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: true)
    }

    private func report(heartbeat: Bool) {
        guard let task else { return }
        reported = latest.nextReported(after: reported, heartbeat: heartbeat)
        task.progress.totalUnitCount = max(1, latest.total * ContinuedBackupProgress.unitsPerItem)
        task.progress.completedUnitCount = reported
    }

    private func adopt(_ task: BGContinuedProcessingTask, window: BackgroundWindow) {
        self.task = task
        let expire: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.expired() }
        }
        task.expirationHandler = expire
        window.adopt(expire)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                self.report(heartbeat: true)
            }
        }
        onStarted?()
    }

    private func expired() {
        guard task != nil else { return }
        onExpired?()
        finish()
    }
}
#endif
