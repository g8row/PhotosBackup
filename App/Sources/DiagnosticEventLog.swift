import Foundation
import OSLog

struct DiagnosticEvent: Codable, Equatable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    /// The most recent occurrence. A folded repeat keeps its first time in
    /// `firstDate`.
    var date: Date
    let level: Level
    let category: String
    let message: String
    /// How many consecutive identical events this entry stands for. Optional,
    /// like `firstDate`, so a log written before repeats were folded decodes.
    var repeatCount: Int?
    var firstDate: Date?

    var occurrences: Int { repeatCount ?? 1 }
}

enum DiagnosticRedactor {
    private static let replacements: [(NSRegularExpression, String)] = [
        (#"(?i)\b(authorization|bearer|oauth_token|access_token|master_token|token|cookie)(\s*[:=]\s*)[^\s,;]+"#, "$1$2<redacted>"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<email>"),
        (#"(?i)https?://[^\s]+"#, "<url>"),
        (#"file:///[^\s]+"#, "<file-url>"),
        (#"(?:/private|/var|/Users)/[^\s]+"#, "<path>"),
        // PhotoKit local identifiers: a UUID, usually followed by /L0/001.
        (#"(?i)\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}(?:/L0/\d+)?"#, "<id>"),
        // Media filenames can carry a person's name, a place or a date.
        (#"(?i)[^\s/\\:"'<>]+\.(?:heic|heif|jpe?g|png|gif|tiff?|dng|webp|avif|mov|mp4|m4v|3gp|avi|hevc)\b"#, "<filename>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ value: String, limit: Int = 1_000) -> String {
        var result = String(value.prefix(limit))
        for (expression, replacement) in replacements {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }
}

/// A small durable event timeline for reports created after a background wake.
///
/// Every entry says what the app decided and why, in terms a support reader can
/// act on. It is written through to disk promptly because the process may be
/// suspended or killed right after the event it describes — and the event just
/// before a crash is the one a report needs most. Writes happen off the
/// caller's thread; `flush()` makes them synchronous where the process is about
/// to be suspended.
///
/// Two rules keep it useful at a fixed size. Identical consecutive events fold
/// into one entry with a count, so a thousand identical retries cost one line.
/// When the log is full, routine `info` entries go before warnings and errors,
/// so a long healthy backup cannot push out the one failure that explains a
/// report. Nothing older than `maximumAge` is kept.
final class DiagnosticEventLog: @unchecked Sendable {
    static let shared = DiagnosticEventLog()
    static let defaultLimit = 400
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "com.g8row.photosbackup", category: "diagnostics")

    private let lock = NSLock()
    private let url: URL
    private let limit: Int
    private let writer = DispatchQueue(label: "com.g8row.photosbackup.diagnostic-log", qos: .utility)
    private var events: [DiagnosticEvent]
    private var writeScheduled = false

    init(url: URL? = nil, limit: Int = defaultLimit) {
        self.limit = max(1, limit)
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("PhotosBackup", isDirectory: true)
        .appendingPathComponent("diagnostic-events-v1.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? decoder.decode([DiagnosticEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
        trimLocked(now: Date())
    }

    func record(
        _ category: String,
        _ message: String,
        level: DiagnosticEvent.Level = .info
    ) {
        let category = DiagnosticRedactor.redact(category, limit: 80)
        let message = DiagnosticRedactor.redact(message, limit: 500)
        // Mirrored to the unified log so Console.app shows the same story live.
        // Already redacted, so it is safe to mark public.
        let type: OSLogType = level == .info ? .default : .error
        Self.logger.log(level: type, "[\(category, privacy: .public)] \(message, privacy: .public)")

        let now = Date()
        lock.lock()
        if var last = events.last, last.level == level,
           last.category == category, last.message == message {
            last.firstDate = last.firstDate ?? last.date
            last.repeatCount = last.occurrences + 1
            last.date = now
            events[events.count - 1] = last
        } else {
            events.append(DiagnosticEvent(date: now, level: level, category: category, message: message))
            trimLocked(now: now)
        }
        let shouldSchedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if shouldSchedule { writer.async { [weak self] in self?.writePending(force: false) } }
    }

    /// Write everything recorded so far before returning. Call where the
    /// process may be suspended next: leaving the foreground, or completing a
    /// background task.
    func flush() {
        writer.sync { writePending(force: true) }
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock()
        let result = events
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        events = []
        writeScheduled = false
        lock.unlock()
        writer.sync { try? FileManager.default.removeItem(at: url) }
    }

    private func trimLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        if let firstRecent = events.firstIndex(where: { $0.date >= cutoff }) {
            if firstRecent > 0 { events.removeFirst(firstRecent) }
        } else {
            events.removeAll()
        }
        guard events.count > limit else { return }
        var excess = events.count - limit
        // Oldest routine entries first; only a log made entirely of warnings
        // and errors starts losing those.
        events.removeAll { event in
            guard excess > 0, event.level == .info else { return false }
            excess -= 1
            return true
        }
        if excess > 0 { events.removeFirst(excess) }
    }

    private func writePending(force: Bool) {
        lock.lock()
        guard writeScheduled || force else {
            lock.unlock()
            return
        }
        writeScheduled = false
        let snapshot = events
        lock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // Diagnostics must never block or change backup behavior.
        }
    }
}
