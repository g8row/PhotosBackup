import Foundation

enum AutomaticBackupRunSource: String, Codable, Sendable {
    case foreground = "App open"
    case manual = "Back Up Now"
    case recheck = "Re-check Backups"
    case backgroundProcessing = "iOS background processing"
    case shortcut = "Shortcuts automation"
    case backgroundTransfer = "Background transfer completion"
    case debugSimulation = "Debug simulation"

    /// Runs the user started by opening the app or tapping a button. They are
    /// the most frequent and say the least about background behaviour, so they
    /// are the first to go when the history is trimmed.
    var isUserStarted: Bool { self == .foreground || self == .manual || self == .recheck }
}

struct AutomaticBackupRunRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: AutomaticBackupRunSource
    let startedAt: Date
    /// The conditions the run started under — app state, network, battery,
    /// Low Power Mode — which is most of the answer to "why did iOS run it
    /// then" and "why did it do so little".
    let context: String?
    var finishedAt: Date?
    var success: Bool?
    var summary: String?

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// A privacy-safe history of backup runs for support: when each one started,
/// what started it, what it ran under, and what it achieved. It stores only
/// the trigger, timestamps, conditions, a success flag, and an aggregate
/// summary. Photo identifiers, filenames, account data, and upload URLs never
/// enter it.
enum AutomaticBackupRunHistory {
    static let recordsKey = "diagnostics.automaticBackup.runs.v1"
    static let limit = 40

    /// Record a run starting. Returns the id `finished` needs, so overlapping
    /// runs — a shortcut during a background window — each close their own
    /// record.
    @discardableResult
    static func started(
        _ source: AutomaticBackupRunSource,
        context: String? = nil,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> UUID {
        let record = AutomaticBackupRunRecord(
            id: UUID(),
            source: source,
            startedAt: now,
            context: context.map { DiagnosticRedactor.redact($0, limit: 300) }
        )
        var records = load(defaults)
        records.append(record)
        trim(&records)
        save(records, defaults)
        DiagnosticEventLog.shared.record(
            "run",
            "Started: \(source.rawValue)" + (context.map { " (\($0))" } ?? "")
        )
        return record.id
    }

    static func finished(
        _ id: UUID,
        success: Bool,
        summary: String,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        var records = load(defaults)
        var label = "Run"
        var elapsed = ""
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].finishedAt = now
            records[index].success = success
            records[index].summary = DiagnosticRedactor.redact(summary, limit: 500)
            label = records[index].source.rawValue
            elapsed = " after \(Int(now.timeIntervalSince(records[index].startedAt).rounded())) s"
            save(records, defaults)
        }
        DiagnosticEventLog.shared.record(
            "run",
            "Finished: \(label)\(elapsed); \(success ? "completed" : "did not complete"); \(summary)",
            level: success ? .info : .warning
        )
    }

    /// Newest first.
    static func recent(defaults: UserDefaults = .standard) -> [AutomaticBackupRunRecord] {
        load(defaults).reversed()
    }

    /// The most recent run from one trigger, for a status line.
    static func latest(
        _ source: AutomaticBackupRunSource,
        defaults: UserDefaults = .standard
    ) -> AutomaticBackupRunRecord? {
        load(defaults).last { $0.source == source }
    }

    private static func trim(_ records: inout [AutomaticBackupRunRecord]) {
        while records.count > limit {
            if let index = records.firstIndex(where: { $0.source.isUserStarted && $0.finishedAt != nil }) {
                records.remove(at: index)
            } else {
                records.removeFirst()
            }
        }
    }

    private static func load(_ defaults: UserDefaults) -> [AutomaticBackupRunRecord] {
        guard let data = defaults.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([AutomaticBackupRunRecord].self, from: data)) ?? []
    }

    private static func save(_ records: [AutomaticBackupRunRecord], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }
}
