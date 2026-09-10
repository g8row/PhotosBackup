import Foundation
import MetricKit

/// One problem iOS reported through MetricKit, reduced to what support needs:
/// what happened, in which build, and where in the code. Call stack frames are
/// binary names and offsets, which carry no personal data and can be
/// symbolicated against the release's dSYM.
struct CrashDiagnosticSummary: Codable, Equatable, Sendable {
    let receivedAt: Date
    let periodEnd: Date
    /// "crash", "hang", "cpu" or "disk-writes".
    let kind: String
    let appVersion: String
    let osVersion: String?
    let detail: String
    let frames: [String]
    let appBinaryUUID: String?
}

struct CrashDiagnosticsSnapshot: Codable, Equatable, Sendable {
    var diagnostics: [CrashDiagnosticSummary] = []
    /// How the app's processes ended over the most recent reporting period.
    var exitSummary: String?
    var exitPeriodEnd: Date?
}

/// Collects crash reports and termination counts from MetricKit.
///
/// iOS delivers these on a later launch — normally the next one — and only
/// when the user shares analytics with app developers (Settings → Privacy &
/// Security → Analytics & Improvements). A memory-limit termination produces no
/// crash report at all; it only shows up in the exit counts, which is why both
/// are kept.
final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticsCollector()
    private static let limit = 10
    private static let frameLimit = 16

    private let lock = NSLock()
    private let url: URL
    private var stored: CrashDiagnosticsSnapshot
    private var started = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotosBackup", isDirectory: true)
            .appendingPathComponent("crash-diagnostics-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stored = (try? Data(contentsOf: self.url))
            .flatMap { try? decoder.decode(CrashDiagnosticsSnapshot.self, from: $0) }
            ?? CrashDiagnosticsSnapshot()
        super.init()
    }

    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        MXMetricManager.shared.add(self)
    }

    func snapshot() -> CrashDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { ingest(payload) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { ingestExits(payload) }
    }

    private func ingest(_ payload: MXDiagnosticPayload) {
        let now = Date()
        var summaries: [CrashDiagnosticSummary] = []
        for crash in payload.crashDiagnostics ?? [] {
            var parts: [String] = []
            if let type = crash.exceptionType?.intValue { parts.append(Self.exceptionName(type)) }
            if let code = crash.exceptionCode?.intValue, code != 0 { parts.append("code \(code)") }
            if let signal = crash.signal?.intValue { parts.append(Self.signalName(signal)) }
            if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
            if #available(iOS 17.0, *), let exception = crash.exceptionReason {
                parts.append("\(exception.exceptionName): \(exception.composedMessage)")
            }
            summaries.append(summary(crash, kind: "crash", periodEnd: payload.timeStampEnd, receivedAt: now,
                                     detail: parts.isEmpty ? "no exception details" : parts.joined(separator: "; "),
                                     tree: crash.callStackTree))
        }
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            summaries.append(summary(hang, kind: "hang", periodEnd: payload.timeStampEnd, receivedAt: now,
                                     detail: String(format: "the main thread was unresponsive for %.1f s", seconds),
                                     tree: hang.callStackTree))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            let used = cpu.totalCPUTime.converted(to: .seconds).value
            let over = cpu.totalSampledTime.converted(to: .seconds).value
            summaries.append(summary(cpu, kind: "cpu", periodEnd: payload.timeStampEnd, receivedAt: now,
                                     detail: String(format: "used %.0f s of CPU within %.0f s", used, over),
                                     tree: cpu.callStackTree))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            let megabytes = disk.totalWritesCaused.converted(to: .megabytes).value
            summaries.append(summary(disk, kind: "disk-writes", periodEnd: payload.timeStampEnd, receivedAt: now,
                                     detail: String(format: "wrote %.0f MB to disk in one day", megabytes),
                                     tree: disk.callStackTree))
        }
        guard !summaries.isEmpty else { return }

        lock.lock()
        let fresh = summaries.filter { candidate in
            !stored.diagnostics.contains {
                $0.periodEnd == candidate.periodEnd && $0.kind == candidate.kind && $0.detail == candidate.detail
            }
        }
        stored.diagnostics.append(contentsOf: fresh)
        if stored.diagnostics.count > Self.limit {
            stored.diagnostics.removeFirst(stored.diagnostics.count - Self.limit)
        }
        let snapshot = stored
        lock.unlock()
        persist(snapshot)

        for item in fresh {
            DiagnosticEventLog.shared.record(
                "crash",
                "iOS reported a \(item.kind == "crash" ? "crash" : item.kind + " problem") in \(item.appVersion): \(item.detail)",
                level: item.kind == "crash" ? .error : .warning
            )
        }
    }

    private func ingestExits(_ payload: MXMetricPayload) {
        guard let exits = payload.applicationExitMetrics else { return }
        let foreground = exits.foregroundExitData
        let background = exits.backgroundExitData
        func line(_ pairs: [(String, Int)]) -> String? {
            let nonzero = pairs.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
            return nonzero.isEmpty ? nil : nonzero.joined(separator: ", ")
        }
        let foregroundLine = line([
            ("normal", foreground.cumulativeNormalAppExitCount),
            ("memory limit", foreground.cumulativeMemoryResourceLimitExitCount),
            ("watchdog", foreground.cumulativeAppWatchdogExitCount),
            ("bad access", foreground.cumulativeBadAccessExitCount),
            ("illegal instruction", foreground.cumulativeIllegalInstructionExitCount),
            ("abnormal", foreground.cumulativeAbnormalExitCount),
        ])
        let backgroundLine = line([
            ("normal", background.cumulativeNormalAppExitCount),
            ("memory limit", background.cumulativeMemoryResourceLimitExitCount),
            ("memory pressure", background.cumulativeMemoryPressureExitCount),
            ("CPU limit", background.cumulativeCPUResourceLimitExitCount),
            ("watchdog", background.cumulativeAppWatchdogExitCount),
            ("background task timeout", background.cumulativeBackgroundTaskAssertionTimeoutExitCount),
            ("locked file", background.cumulativeSuspendedWithLockedFileExitCount),
            ("bad access", background.cumulativeBadAccessExitCount),
            ("illegal instruction", background.cumulativeIllegalInstructionExitCount),
            ("abnormal", background.cumulativeAbnormalExitCount),
        ])
        guard foregroundLine != nil || backgroundLine != nil else { return }
        let summary = "foreground: \(foregroundLine ?? "none"); background: \(backgroundLine ?? "none")"

        lock.lock()
        stored.exitSummary = summary
        stored.exitPeriodEnd = payload.timeStampEnd
        let snapshot = stored
        lock.unlock()
        persist(snapshot)

        let abnormal = foreground.cumulativeMemoryResourceLimitExitCount
            + foreground.cumulativeAppWatchdogExitCount
            + foreground.cumulativeBadAccessExitCount
            + foreground.cumulativeIllegalInstructionExitCount
            + foreground.cumulativeAbnormalExitCount
            + background.cumulativeMemoryResourceLimitExitCount
            + background.cumulativeCPUResourceLimitExitCount
            + background.cumulativeAppWatchdogExitCount
            + background.cumulativeBackgroundTaskAssertionTimeoutExitCount
            + background.cumulativeBadAccessExitCount
            + background.cumulativeIllegalInstructionExitCount
            + background.cumulativeAbnormalExitCount
        DiagnosticEventLog.shared.record(
            "crash",
            "iOS reported how the app's processes ended over the last day — \(summary)",
            level: abnormal > 0 ? .warning : .info
        )
    }

    private func summary(_ diagnostic: MXDiagnostic, kind: String, periodEnd: Date, receivedAt: Date,
                         detail: String, tree: MXCallStackTree) -> CrashDiagnosticSummary {
        let (frames, uuid) = Self.frames(from: tree)
        return CrashDiagnosticSummary(
            receivedAt: receivedAt,
            periodEnd: periodEnd,
            kind: kind,
            appVersion: "\(diagnostic.applicationVersion) (\(diagnostic.metaData.applicationBuildVersion))",
            osVersion: diagnostic.metaData.osVersion,
            detail: DiagnosticRedactor.redact(detail, limit: 400),
            frames: frames,
            appBinaryUUID: uuid
        )
    }

    /// The attributed thread's frames, innermost first, as "binary +offset".
    /// MetricKit nests each caller as the first sub-frame of its callee.
    static func frames(from tree: MXCallStackTree) -> ([String], String?) {
        guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]],
              let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        else { return ([], nil) }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        var frames: [String] = []
        var appUUID: String?
        var frame = (stack["callStackRootFrames"] as? [[String: Any]])?.first
        while let current = frame, frames.count < frameLimit {
            let name = current["binaryName"] as? String ?? "?"
            let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? 0
            frames.append("\(name) +0x\(String(offset, radix: 16))")
            if name == appName, appUUID == nil { appUUID = current["binaryUUID"] as? String }
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return (frames, appUUID)
    }

    static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT (Swift runtime trap)"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "exception type \(type)"
        }
    }

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        default: return "signal \(signal)"
        }
    }

    private func persist(_ snapshot: CrashDiagnosticsSnapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // Diagnostics must never block or change backup behavior.
        }
    }
}
