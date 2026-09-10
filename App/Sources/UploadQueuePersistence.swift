import Foundation

/// The durable subset of a media source. Picker-only selections cannot be
/// reconstructed after process death, while library assets and file URLs can.
enum PersistedMediaSource: Codable, Equatable, Sendable {
    case asset(String)
    case file(String)

    init?(_ source: MediaSource) {
        switch source {
        case .asset(let identifier): self = .asset(identifier)
        case .file(let url): self = .file(url.standardizedFileURL.path)
        case .picked: return nil
        }
    }

    var mediaSource: MediaSource {
        switch self {
        case .asset(let identifier): return .asset(localIdentifier: identifier)
        case .file(let path): return .file(URL(fileURLWithPath: path))
        }
    }
}

/// Durable hand-off between export, background PUT, and commit. A checkpoint
/// without `prepared` resumes preflight; one with a nil receipt reattaches to
/// the background task; one with a receipt skips straight to commit.
struct UploadCheckpoint: Codable, Equatable, Sendable {
    let filePath: String
    let filename: String
    let modified: Date
    let byteCount: Int64
    let temporary: Bool
    var prepared: PreparedUpload?
    var continuesAfterProcessExit: Bool? = nil
    /// Set once an unusable receipt has already cost this item a fresh transfer.
    /// A second identical rejection is not the receipt, so the item fails
    /// instead of re-uploading its bytes for every remaining attempt.
    var retriedAfterInvalidReceipt: Bool? = nil

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var isBackgroundTransfer: Bool { prepared != nil && continuesAfterProcessExit == true }
}

struct PersistedUploadItem: Codable, Equatable, Sendable {
    let id: UUID
    let source: PersistedMediaSource
    let name: String
    let byteCount: Int64
    let attempts: Int
    let failureReason: String?
    let failureRetryable: Bool
    let checkpoint: UploadCheckpoint?
    /// Optional so snapshots written by earlier releases remain decodable.
    let cancelled: Bool?
    /// How many times the process died while this row was being prepared. Nil
    /// for zero, so ordinary rows are encoded exactly as before.
    let interruptedPreparations: Int?

    init(id: UUID, source: PersistedMediaSource, name: String, byteCount: Int64,
         attempts: Int, failureReason: String?, failureRetryable: Bool,
         checkpoint: UploadCheckpoint? = nil, cancelled: Bool? = nil,
         interruptedPreparations: Int? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.byteCount = byteCount
        self.attempts = attempts
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.checkpoint = checkpoint
        self.cancelled = cancelled
        self.interruptedPreparations = interruptedPreparations
    }
}

/// Remembers which rows were mid-preparation — exporting from Photos, hashing,
/// asking Google for an upload URL — while the app was executing. A row still
/// marked at the next launch was being prepared when the process died, which is
/// what a crash or a memory-limit termination on that one item looks like.
protocol PreparationMarkerStoring: AnyObject {
    func load() -> Set<UUID>
    func save(_ ids: Set<UUID>)
}

/// UserDefaults rather than a file: each write reaches cfprefsd straight away,
/// so it survives the process being killed a moment later — the only case
/// these markers exist for.
final class UserDefaultsPreparationMarkers: PreparationMarkerStoring {
    private let defaults: UserDefaults
    private let key = "queue.preparingItemIDs.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func save(_ ids: Set<UUID>) {
        if ids.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(ids.map(\.uuidString).sorted(), forKey: key) }
    }
}

final class MemoryPreparationMarkers: PreparationMarkerStoring {
    private(set) var ids: Set<UUID>

    init(_ ids: Set<UUID> = []) { self.ids = ids }

    func load() -> Set<UUID> { ids }
    func save(_ ids: Set<UUID>) { self.ids = ids }
}

struct UploadQueueSnapshot: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let accountIdentifier: String
    let items: [PersistedUploadItem]
    let completedSourceKeys: [String]
    /// Optional so snapshots written by earlier releases remain decodable.
    let isUserPaused: Bool?

    init(version: Int, accountIdentifier: String, items: [PersistedUploadItem],
         completedSourceKeys: [String], isUserPaused: Bool? = nil) {
        self.version = version
        self.accountIdentifier = accountIdentifier
        self.items = items
        self.completedSourceKeys = completedSourceKeys
        self.isUserPaused = isUserPaused
    }
}

protocol UploadQueuePersisting {
    func load() throws -> UploadQueueSnapshot?
    func save(_ snapshot: UploadQueueSnapshot) throws
    var storesCompletionLedgerSeparately: Bool { get }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String]
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws
    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws
}

extension UploadQueuePersisting {
    var storesCompletionLedgerSeparately: Bool { false }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        guard let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier else { return [] }
        return snapshot.completedSourceKeys
    }
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {}
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws {
        for key in keys { try recordCompletedSourceKey(key, for: accountIdentifier) }
    }
    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {}
}

/// Stores one account-scoped queue atomically in Application Support. The file
/// remains readable after the first device unlock so an iOS background task can
/// restore it while the phone is locked.
struct FileUploadQueuePersistence: UploadQueuePersisting {
    private let url: URL
    private let ledgerURL: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
            ledgerURL = url.deletingLastPathComponent().appendingPathComponent("completed-sources-v1.log")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("upload-queue-v1.json")
            ledgerURL = base.appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("completed-sources-v1.log")
        }
    }

    var storesCompletionLedgerSeparately: Bool { true }

    func load() throws -> UploadQueueSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UploadQueueSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: UploadQueueSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        var keys: [String] = []
        if let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier {
            keys.append(contentsOf: snapshot.completedSourceKeys)
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return keys }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let contents = try String(contentsOf: ledgerURL, encoding: .utf8)
        var lineCount = 0
        var seen = Set<String>()
        var ownKeys: [String] = []
        var otherAccountLines: [String] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            lineCount += 1
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(account),
                  let data = Data(base64Encoded: String(parts[1])) else {
                otherAccountLines.append(String(line))
                continue
            }
            let key = String(decoding: data, as: UTF8.self)
            if seen.insert(key).inserted { ownKeys.append(key) }
        }
        keys.append(contentsOf: ownKeys)
        // The ledger only ever appends, so a source that is re-verified or
        // re-uploaded leaves a line each time. Rewrite it once the duplicates
        // outweigh the real entries, otherwise every launch pays to parse them.
        let distinct = ownKeys.count + otherAccountLines.count
        if lineCount > 512, lineCount > distinct * 2 {
            try? rewriteLedger(ownKeys: ownKeys, account: account, otherLines: otherAccountLines)
        }
        return keys
    }

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        try recordCompletedSourceKeys([key], for: accountIdentifier)
    }

    /// Append in one pass. The snapshot-to-ledger migration hands over every
    /// remembered key at once, and opening a file handle per key made the first
    /// launch after upgrading a large library take minutes.
    func recordCompletedSourceKeys(_ keys: [String], for accountIdentifier: String) throws {
        guard !keys.isEmpty else { return }
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            guard FileManager.default.createFile(atPath: ledgerURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let payload = keys
            .map { account + "\t" + Data($0.utf8).base64EncodedString() + "\n" }
            .joined()
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(payload.utf8))
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: ledgerURL.path
        )
    }

    private func rewriteLedger(ownKeys: [String], account: String, otherLines: [String]) throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let own = ownKeys.map { account + "\t" + Data($0.utf8).base64EncodedString() }
        let lines = otherLines + own
        let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try output.write(to: ledgerURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: ledgerURL.path
        )
    }

    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {
        guard !keys.isEmpty else { return }
        // Snapshot may still carry keys written before the separate ledger existed.
        if let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier,
           !snapshot.completedSourceKeys.isEmpty {
            let remaining = snapshot.completedSourceKeys.filter { !keys.contains($0) }
            if remaining.count != snapshot.completedSourceKeys.count {
                try save(UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: remaining,
                                            isUserPaused: snapshot.isUserPaused))
            }
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let contents = try String(contentsOf: ledgerURL, encoding: .utf8)
        var kept: [String] = []
        var removed = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(account),
                  let data = Data(base64Encoded: String(parts[1])) else {
                kept.append(String(line))
                continue
            }
            if keys.contains(String(decoding: data, as: UTF8.self)) { removed = true }
            else { kept.append(String(line)) }
        }
        guard removed else { return }
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try output.write(to: ledgerURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: ledgerURL.path
        )
    }
}

final class MemoryUploadQueuePersistence: UploadQueuePersisting {
    var snapshot: UploadQueueSnapshot?
    /// How many whole-snapshot writes the queue has asked for. The real file
    /// store encodes and atomically replaces the file on each one, so a bulk
    /// command that writes per row is a main-thread stall proportional to the
    /// square of the queue length.
    private(set) var saveCount = 0

    init(snapshot: UploadQueueSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() throws -> UploadQueueSnapshot? { snapshot }
    func save(_ snapshot: UploadQueueSnapshot) throws {
        saveCount += 1
        self.snapshot = snapshot
    }

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        guard let snapshot, snapshot.accountIdentifier == accountIdentifier,
              !snapshot.completedSourceKeys.contains(key) else { return }
        self.snapshot = UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: snapshot.completedSourceKeys + [key],
                                            isUserPaused: snapshot.isUserPaused)
    }

    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {
        guard !keys.isEmpty, let snapshot, snapshot.accountIdentifier == accountIdentifier else { return }
        let remaining = snapshot.completedSourceKeys.filter { !keys.contains($0) }
        guard remaining.count != snapshot.completedSourceKeys.count else { return }
        self.snapshot = UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: remaining,
                                            isUserPaused: snapshot.isUserPaused)
    }
}
