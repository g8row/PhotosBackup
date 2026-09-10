import Foundation
import CryptoKit

/// The `google.rpc.Status` Google puts in a protobuf error body: a canonical
/// code in field 1, an English message in field 2. The code is the half worth
/// branching on — the message is prose Google can reword at any time, and it
/// only reads as English because every request pins `Accept-Language: en_US`.
struct GoogleStatus: Equatable, Sendable {
    /// `google.rpc.Code`, limited to the values this app can act on. Anything
    /// else keeps its number in `rawCode` and changes no behaviour.
    enum Code: Int, Equatable, Sendable {
        case invalidArgument = 3
        case deadlineExceeded = 4
        case permissionDenied = 7
        case resourceExhausted = 8
        case failedPrecondition = 9
        case aborted = 10
        case unavailable = 14
        case unauthenticated = 16
    }
    let rawCode: Int
    let message: String?
    var code: Code? { Code(rawValue: rawCode) }

    /// Fails when the body is not a status: not protobuf, no code, or a code of
    /// zero, which is `OK` and cannot describe a failure.
    init?(_ data: Data) {
        // `try?` flattens the throw and the "no such field" nil into one
        // optional: either there is a code, or this is not a status.
        guard !data.isEmpty, let number = try? Proto.number(1, in: data), number > 0,
              let value = Int(exactly: number) else { return nil }
        rawCode = value
        message = (try? Proto.string(at: [2], in: data)) ?? nil
    }

    /// What this code means for the item it was raised against, or nil to keep
    /// the classification the HTTP status already implies. Only the codes where
    /// the app would do something different are mapped.
    func kind(httpStatus: Int) -> GPMCError.Kind? {
        switch code {
        case .resourceExhausted:
            // Rate limiting shares this code and arrives as 429, which is
            // already classified as retryable. Anything else means the account
            // itself has no room left, which retrying cannot fix.
            return httpStatus == 429 ? nil : .storageFull
        case .unauthenticated, .permissionDenied:
            return .credentialRejected
        default:
            return nil
        }
    }
}

struct GPMCError: LocalizedError, Equatable {
    /// What went wrong, in the terms a caller has to act on: reconnect the
    /// account, try again later, or give up on this item.
    enum Kind: Equatable, Sendable {
        case credentialRejected   // Google refused the credential; the account must be reconnected.
        case tokenBound           // TokenEncrypted=1 — a bound token this build deliberately does not use.
        case transport            // Network-level failure.
        case server(Int)          // Non-2xx from Google.
        case malformed            // A response we could not make sense of.
        case invalidUploadReceipt // Restart preflight/PUT; never replay this receipt.
        case storageFull          // Google says the account has no room left.
    }
    let kind: Kind
    let message: String
    /// The status Google returned, when it sent one. Carried so a caller can
    /// read the canonical code rather than pattern-match the message text.
    let status: GoogleStatus?
    init(kind: Kind = .malformed, message: String, status: GoogleStatus? = nil) {
        self.kind = kind; self.message = message; self.status = status
    }
    var errorDescription: String? { message }

    /// `localizedDescription` collapses to "unknown error" for several URL
    /// error codes, which makes a failed row impossible to act on. Keep the
    /// readable text where there is one, and fall back to domain and code.
    static func describeTransport(_ error: Error) -> String {
        let nsError = error as NSError
        let described = nsError.localizedDescription
        let useless = described.isEmpty
            || described.localizedCaseInsensitiveContains("unknown error")
        guard useless else { return described }
        if let urlError = error as? URLError {
            return "\(urlError.code) (URLError \(urlError.errorCode))"
        }
        return "\(nsError.domain) \(nsError.code)"
    }

    /// True when trying again may succeed without the user doing anything.
    var isRetryable: Bool {
        switch kind {
        case .transport, .invalidUploadReceipt: return true
        case .server(let code): return code == 408 || code == 429 || code >= 500
        case .credentialRejected, .tokenBound, .malformed, .storageFull: return false
        }
    }
}

/// What the server had to say about one item once the upload finished.
enum UploadOutcome: Equatable, Sendable {
    case uploaded(mediaKey: String)
    case alreadyBackedUp(mediaKey: String)
    var mediaKey: String {
        switch self { case .uploaded(let key), .alreadyBackedUp(let key): return key }
    }
}

/// Byte-level progress for one upload. Reported synchronously so it can come
/// straight out of a `URLSessionTaskDelegate` callback; callers that need
/// ordering should funnel it through an `AsyncStream`.
enum UploadPhase: Equatable, Sendable {
    case hashing(fraction: Double)
    case checkingDuplicate
    case preparing
    case sending(sent: Int64, total: Int64)
    case finalizing
}

/// Result of the preflight half of an upload. The expensive PUT is deliberately
/// split from the RPCs around it so production can hand only that file transfer
/// to a background URL session while tests keep using their injected session.
enum UploadPreparation: Equatable, Sendable {
    case alreadyBackedUp(mediaKey: String)
    case ready(PreparedUpload)
}

/// Everything needed to resume at the PUT or commit boundary after a process
/// relaunch. The app persists this alongside its queue item.
///
/// Deliberately carries no quality or quota choice. Those only ever reach the
/// wire in `commit`, and a checkpoint can outlive the settings it was made
/// under — persisting them meant an item prepared while Storage Saver was on
/// kept committing as Storage Saver after the toggle went off, including across
/// a relaunch. `commit` takes them from the live options instead.
struct PreparedUpload: Codable, Equatable, Sendable {
    let uploadURL: URL
    let hash: Data
    let filename: String
    let modified: Date
    let byteCount: Int64
    var receipt: Data?
}

struct FileUploadResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// Transport seam for the file PUT. Background URL sessions cannot use the
/// async upload convenience API or URLProtocol, so the app supplies a delegate-
/// driven implementation while unit tests retain this foreground implementation.
protocol FileUploadTransport: Sendable {
    var continuesAfterProcessExit: Bool { get }
    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult
    func cancel(transferID: UUID) async
    func forget(transferID: UUID) async
}

struct AuthData {
    let values: [String: String]
    static let required = ["androidId", "client_sig", "callerSig", "device_country", "Email", "google_play_services_version", "lang", "oauth2_foreground", "sdk_version", "service", "Token"]
    init(_ text: String) throws {
        var parsed: [String: String] = [:]
        for pair in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            func decode(_ s: Substring) -> String { String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
            parsed[decode(parts[0])] = decode(parts[1])
        }
        let missing = Self.required.filter { parsed[$0, default: ""].isEmpty }
        guard missing.isEmpty else { throw GPMCError(kind: .credentialRejected, message: "Missing auth fields: " + missing.joined(separator: ", ")) }
        values = parsed
    }
    var body: Data {
        var values = values.filter { Self.required.contains($0.key) }
        values["app"] = "com.google.android.apps.photos"; values["callerPkg"] = "com.google.android.apps.photos"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.keys.sorted().map { key in
            key + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

private func drainingAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
#if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
#else
    try body()
#endif
}

/// Forwards `URLSession` upload progress. A per-task delegate, so one instance
/// serves exactly one request and dies with it.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let report: @Sendable (Int64, Int64) -> Void
    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, max(totalBytesExpectedToSend, totalBytesSent))
    }
}

final class ForegroundFileUploadTransport: FileUploadTransport, @unchecked Sendable {
    let continuesAfterProcessExit = false
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult {
        let delegate = ProgressDelegate(progress)
        do {
            let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw GPMCError(message: "Invalid server response.")
            }
            return FileUploadResult(data: data, response: http)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GPMCError {
            throw error
        } catch {
            throw GPMCError(kind: .transport, message: "Could not reach Google: \(GPMCError.describeTransport(error))")
        }
    }

    func forget(transferID: UUID) async {}
    func cancel(transferID: UUID) async {}
}

/// Thread-safe request policy shared by every client created for an account.
/// Queue-level path monitoring controls when work starts; these request flags
/// are the second line of defence that prevents a task from moving to cellular.
final class UploadRequestNetworkPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var cellularAllowed = true

    func setCellularAllowed(_ allowed: Bool) {
        lock.lock()
        cellularAllowed = allowed
        lock.unlock()
    }

    func apply(to request: inout URLRequest) {
        lock.lock()
        let allowed = cellularAllowed
        lock.unlock()
        request.allowsCellularAccess = allowed
        request.allowsExpensiveNetworkAccess = allowed
    }
}

actor GPMCClient {
    private let auth: AuthData
    private let session: URLSession
    private let networkPolicy: UploadRequestNetworkPolicy
    private let fileUploadTransport: any FileUploadTransport
    private var token = ""
    private var expiry = Date.distantPast
    private let userAgent = "com.google.android.apps.photos/49029607 (Linux; U; Android 9; en_US; Pixel XL; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)"
    init(authData: String,
         session: URLSession? = nil,
         networkPolicy: UploadRequestNetworkPolicy = UploadRequestNetworkPolicy(),
         fileUploadTransport: (any FileUploadTransport)? = nil) throws {
        auth = try AuthData(authData)
        self.networkPolicy = networkPolicy
        if let session {
            self.session = session
            self.fileUploadTransport = fileUploadTransport ?? ForegroundFileUploadTransport(session: session)
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 60 * 60
            // These authenticated protobuf calls are stateful and never benefit
            // from an HTTP response cache. Keeping it disabled also avoids a
            // growing Cache.db full of private API responses.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            self.session = session
            self.fileUploadTransport = fileUploadTransport ?? ForegroundFileUploadTransport(session: session)
        }
    }
    var accountEmail: String { auth.values["Email"] ?? "" }

    private func checked(_ data: Data, _ response: URLResponse, operation: String = "request") throws -> (Data, HTTPURLResponse) {
        guard let http = response as? HTTPURLResponse else { throw GPMCError(message: "Invalid server response.") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GPMCError(kind: .credentialRejected, message: "Google rejected the stored credential (HTTP \(http.statusCode)). Connect the account again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let status = GoogleStatus(data)
            let detail = Self.explanation(data)
            switch status?.kind(httpStatus: http.statusCode) {
            case .storageFull:
                throw GPMCError(kind: .storageFull,
                                message: "The Google account is out of storage. Free up space in Google Photos, then resume."
                                    + detail, status: status)
            case .credentialRejected:
                throw GPMCError(kind: .credentialRejected,
                                message: "Google rejected the stored credential during \(operation). Connect the account again."
                                    + detail, status: status)
            default:
                throw GPMCError(kind: .server(http.statusCode),
                                message: "Google returned HTTP \(http.statusCode) during \(operation)."
                                    + detail, status: status)
            }
        }
        return (data, http)
    }
    /// Google's error bodies are the only thing that says *why* a request was
    /// rejected. Prefer the status message, fall back to a printable body, and
    /// keep the hex prefix for anything else — a truncated or unknown binary
    /// response is still enough to identify the failure.
    static func explanation(_ data: Data, limit: Int = 240) -> String {
        guard !data.isEmpty else { return "" }
        let text = GoogleStatus(data)?.message ?? String(decoding: data, as: UTF8.self)
        let printable = !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F)
        }
        let detail: String
        if printable {
            detail = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit).description
        } else {
            detail = "0x" + data.prefix(limit / 4).map { String(format: "%02x", $0) }.joined()
        }
        return detail.isEmpty ? "" : " Google said: \(detail)"
    }
    private func send(_ originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        var request = originalRequest
        networkPolicy.apply(to: &request)
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GPMCError(kind: .transport, message: "Could not reach Google: \(GPMCError.describeTransport(error))")
        }
    }
    func authenticate() async throws {
        var request = URLRequest(url: URL(string: "https://android.googleapis.com/auth")!); request.httpMethod = "POST"
        request.httpBody = auth.body; request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.photos", forHTTPHeaderField: "app")
        request.setValue(auth.values["androidId"], forHTTPHeaderField: "device")
        request.setValue("GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await send(request)
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        if fields["TokenEncrypted"] == "1" {
            throw GPMCError(kind: .tokenBound, message: "Google returned an encrypted (bound) token. This build does not implement token binding; import an unbound credential.")
        }
        // The endpoint answers a dead master token with 200 or 403 plus an
        // `Error=` line, so read the body before judging the status code.
        if let code = fields["Error"], !code.isEmpty {
            throw GPMCError(kind: .credentialRejected, message: "Google rejected the stored credential (\(code)). Connect the account again.")
        }
        _ = try checked(data, response, operation: "authentication")
        guard let value = fields["Auth"], !value.isEmpty else { throw GPMCError(kind: .credentialRejected, message: "Google did not issue a token. Connect the account again.") }
        token = value; expiry = Date(timeIntervalSince1970: Double(fields["Expiry"] ?? "") ?? Date().addingTimeInterval(300).timeIntervalSince1970)
    }

    /// Read-only credential check: authenticate, then run a dummy hash lookup
    /// (mirrors gotohp's FindRemoteMediaByHash validation). Returns the account
    /// email echoed by nothing here, so callers just care that it does not throw.
    func validateReadAccess() async throws {
        try await authenticate()
        let dummyHash = Data(repeating: 0, count: 20)
        let check = Proto.bytes(1, Proto.bytes(1, Proto.bytes(1, dummyHash)) + Proto.bytes(2, Data()))
        _ = try await rpc(Self.hashCheckMethod, body: check)
    }
    private func request(_ url: URL, method: String = "POST", body: Data? = nil, headers: [String: String] = [:], operation: String = "request", allowReauth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en_US", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let result = try await send(request)
        // The expiry check above only covers a token that ages out between
        // calls. A token revoked elsewhere dies mid-session, so spend one forced
        // refresh on the small replayable data request. File PUTs bypass this
        // helper and retain their own upload ID.
        if allowReauth, let http = result.1 as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            expiry = .distantPast
            return try await self.request(url, method: method, body: body, headers: headers, operation: operation, allowReauth: false)
        }
        return try checked(result.0, result.1, operation: operation)
    }
    // photosdata-pa method ids (gotohp @ 0637c745, backend/api.go).
    private static let hashCheckMethod = "5084965799730810217"
    private static let commitMethod = "16538846908252377752"
    /// Only some photosdata-pa calls carry these. `doCommitRequest`,
    /// `CreateAlbum` and `AddMediaToAlbum` set them upstream;
    /// `FindRemoteMediaByHash` deliberately does not, and sending them on the
    /// hash lookup gets the request rejected with HTTP 400.
    private static let extHeaders = [
        "x-goog-ext-173412678-bin": "CgcIAhClARgC",
        "x-goog-ext-174067345-bin": "CgIIAg==",
    ]
    private func rpc(_ method: String, body: Data, ext: Bool = false) async throws -> Data {
        try await request(URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/" + method)!,
                          body: body, headers: ext ? Self.extHeaders : [:],
                          operation: method == Self.commitMethod ? "finalization" : "duplicate check").0
    }

    /// Hash and de-duplicate while the app is awake, then obtain the resumable
    /// upload URL. No long-running body transfer happens in this method.
    func prepareUpload(file: URL, filename: String, modified: Date? = nil,
                       phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadPreparation {
        let declared = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard declared > 0 else { throw GPMCError(message: "That item is empty; there is nothing to upload.") }
        phase(.hashing(fraction: 0))
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hasher = Insecure.SHA1(); var size: UInt64 = 0; var reachedEnd = false
        // One pool per chunk. This loop never suspends, so an autoreleased read
        // buffer would otherwise live until the whole file is hashed — for a
        // multi-gigabyte video, enough to reach iOS's per-app memory limit.
        while !reachedEnd {
            try drainingAutoreleasePool {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                try Task.checkCancellation(); hasher.update(data: chunk); size += UInt64(chunk.count)
                phase(.hashing(fraction: min(1, Double(size) / Double(declared))))
            }
        }
        let hash = Data(hasher.finalize())
        phase(.checkingDuplicate)
        let check = Proto.bytes(1, Proto.bytes(1, Proto.bytes(1, hash)) + Proto.bytes(2, Data()))
        let existing = try await rpc(Self.hashCheckMethod, body: check)
        if let key = try Proto.string(at: [1, 2, 2, 1], in: existing) {
            return .alreadyBackedUp(mediaKey: key)
        }
        phase(.preparing)
        let endpoint = URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive")!
        let body = Proto.int(1, 2) + Proto.int(2, 2) + Proto.int(3, 1) + Proto.int(4, 3) + Proto.int(7, size)
        let (_, response) = try await request(endpoint, body: body, headers: ["X-Goog-Hash": "sha1=" + hash.base64EncodedString(), "X-Upload-Content-Length": String(size)], operation: "upload initialization")
        guard let uploadID = response.value(forHTTPHeaderField: "X-GUploader-UploadID"), !uploadID.isEmpty else { throw GPMCError(message: "Google did not return an upload ID.") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "upload_id", value: uploadID)]
        let date = modified ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return .ready(PreparedUpload(uploadURL: components.url!, hash: hash, filename: filename,
                                     modified: date, byteCount: Int64(size), receipt: nil))
    }

    /// Run (or reattach to) the file PUT through the injected transport.
    func transfer(_ prepared: PreparedUpload, file: URL, transferID: UUID, foreground: Bool = false,
                  phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> PreparedUpload {
        if let receipt = prepared.receipt {
            try Self.validateReceipt(receipt)
            return prepared
        }
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        var request = URLRequest(url: prepared.uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7 * 24 * 60 * 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en_US", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        networkPolicy.apply(to: &request)
        let total = prepared.byteCount
        phase(.sending(sent: 0, total: total))
        let transport: any FileUploadTransport = foreground ? ForegroundFileUploadTransport(session: session) : fileUploadTransport
        let result = try await transport.upload(request, fromFile: file, transferID: transferID) { sent, expected in
            phase(.sending(sent: sent, total: expected > 0 ? expected : total))
        }
        let (receipt, _) = try checked(result.data, result.response, operation: "file transfer")
        try Self.validateReceipt(receipt)
        var completed = prepared
        completed.receipt = receipt
        return completed
    }

    /// CommitToken's field 2 contains the opaque upload token. Parsing alone
    /// accepts an empty message (or an unrelated protobuf error) as a receipt.
    /// Validate both fresh responses and checkpoints written by older builds.
    static func validateReceipt(_ receipt: Data) throws {
        guard let fields = try? Proto.fields(receipt),
              let token = fields[2]?.first, !token.isEmpty else {
            throw GPMCError(kind: .invalidUploadReceipt,
                            message: "Google did not return a usable upload receipt. The file must be transferred again.")
        }
    }

    /// Whether a commit failure says the receipt itself is unusable, so the
    /// item is worth another preflight and transfer rather than being failed.
    ///
    /// `INVALID_ARGUMENT` is the structural signal: every other argument in the
    /// commit body is rebuilt from the checkpoint on each attempt, so the only
    /// one that can have gone stale since the PUT is the upload token inside
    /// the receipt. A metadata bug of our own would land here too, and cost up
    /// to `maxAttempts` transfers per item — bounded, and preflight's hash
    /// lookup returns `alreadyBackedUp` for bytes that did reach Google.
    ///
    /// The message check is the fallback for a rejection that arrives without a
    /// parseable status. It was the only signal before, and it is the wording
    /// Google returned when this was reproduced live.
    static func rejectsReceipt(_ error: GPMCError) -> Bool {
        guard case .server = error.kind else { return false }
        if let code = error.status?.code { return code == .invalidArgument }
        return error.message.localizedCaseInsensitiveContains("valid blueprint")
    }

    /// The device model and quality code a commit declares, the same mapping
    /// upstream gpmc uses. The model decides how Google accounts for the
    /// upload's storage — an older Pixel's uploads do not count against it — and
    /// the quality code asks for original bytes (3) or Storage Saver (1). The
    /// Google Photos app labels an upload from the free-storage models "Storage
    /// saver" even when the original bytes were kept, which is what issue #11
    /// reports. Exposed so Diagnostics shows exactly what was sent.
    static func commitProfile(useQuota: Bool, saver: Bool) -> (model: String, quality: UInt64) {
        (useQuota ? "Pixel 8" : (saver ? "Pixel 2" : "Pixel XL"), saver ? 1 : 3)
    }

    /// Commit the receipt. This is intentionally a small data request that runs
    /// during the background-session relaunch window.
    ///
    /// `useQuota` and `saver` are passed per call rather than read back off
    /// `prepared`, so the committed policy is always the one the user has set
    /// now, not the one in force when the item was prepared.
    func commit(_ prepared: PreparedUpload, useQuota: Bool, saver: Bool,
                phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadOutcome {
        guard let receipt = prepared.receipt else {
            throw GPMCError(message: "The upload has not finished transferring yet.")
        }
        try Self.validateReceipt(receipt)
        phase(.finalizing)
        let stamp = UInt64(max(0, prepared.modified.timeIntervalSince1970))
        let profile = Self.commitProfile(useQuota: useQuota, saver: saver)
        let metadata = Proto.bytes(1, receipt) + Proto.string(2, prepared.filename) + Proto.bytes(3, prepared.hash) + Proto.bytes(4, Proto.int(1, stamp) + Proto.int(2, 46_000_000)) + Proto.int(7, profile.quality) + Proto.int(10, 1)
        let device = Proto.string(3, profile.model) + Proto.string(4, "Google") + Proto.int(5, 28)
        let committed: Data
        do {
            committed = try await rpc(Self.commitMethod, body: Proto.bytes(1, metadata) + Proto.bytes(2, device) + Proto.bytes(3, Data([1, 3])), ext: true)
        } catch let error as GPMCError where Self.rejectsReceipt(error) {
            throw GPMCError(kind: .invalidUploadReceipt, message: error.message, status: error.status)
        }
        guard let key = try Proto.string(at: [1, 3, 1], in: committed) else { throw GPMCError(message: "Google rejected the upload during finalization.") }
        return .uploaded(mediaKey: key)
    }

    func forgetTransfer(_ transferID: UUID) async {
        await fileUploadTransport.forget(transferID: transferID)
    }

    func cancelTransfer(_ transferID: UUID) async {
        await fileUploadTransport.cancel(transferID: transferID)
    }

    var usesBackgroundFileTransfers: Bool { fileUploadTransport.continuesAfterProcessExit }

    /// Convenience orchestration retained for callers and the existing protocol-
    /// based test suite. Production's PhotosUploader persists each boundary.
    func upload(file: URL, filename: String, modified: Date? = nil, useQuota: Bool, saver: Bool,
                phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadOutcome {
        switch try await prepareUpload(file: file, filename: filename, modified: modified,
                                       phase: phase) {
        case .alreadyBackedUp(let key):
            return .alreadyBackedUp(mediaKey: key)
        case .ready(let prepared):
            let transferID = UUID()
            let completed = try await transfer(prepared, file: file, transferID: transferID, phase: phase)
            defer { Task { await self.forgetTransfer(transferID) } }
            return try await commit(completed, useQuota: useQuota, saver: saver, phase: phase)
        }
    }
}
