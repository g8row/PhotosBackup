import XCTest
import CryptoKit
@testable import PhotosBackup

private final class RecordingFileUploadTransport: FileUploadTransport, @unchecked Sendable {
    let continuesAfterProcessExit = true
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let receipt: Data

    init(receipt: Data = Proto.int(1, 1) + Proto.bytes(2, Data("background-receipt".utf8))) {
        self.receipt = receipt
    }

    private func record(_ request: URLRequest) {
        lock.lock(); requests.append(request); lock.unlock()
    }

    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult {
        record(request)
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        progress(size, size)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        return FileUploadResult(data: receipt, response: response)
    }

    func forget(transferID: UUID) async {}
    func cancel(transferID: UUID) async {}
}

final class GPMCClientTests: XCTestCase {

    // A credential body with every field `AuthData.required` insists on.
    private static let credential = TokenExchange.googlePhotosCredentialBody(
        androidId: "0123456789abcdef", email: "person@gmail.com", masterToken: "aas_et/master+token")

    private static let farFuture = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))

    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    // MARK: - AuthData

    func testAuthDataRoundTripsTheCredentialTokenExchangeProduces() throws {
        let auth = try AuthData(Self.credential)
        XCTAssertEqual(auth.values["Email"], "person@gmail.com")
        // '/' and '+' are percent-encoded on the way out and must come back intact.
        XCTAssertEqual(auth.values["Token"], "aas_et/master+token")
        XCTAssertEqual(auth.values["androidId"], "0123456789abcdef")
    }

    func testAuthDataNamesTheMissingFieldsAndReadsAsARejection() {
        XCTAssertThrowsError(try AuthData("Email=a@b.com&Token=x")) { error in
            let gpmc = error as? GPMCError
            XCTAssertEqual(gpmc?.kind, .credentialRejected)
            XCTAssertTrue(gpmc?.message.contains("androidId") ?? false)
            XCTAssertTrue(gpmc?.message.contains("oauth2_foreground") ?? false)
        }
    }

    func testAuthDataBodyIsSortedAndCarriesThePhotosPackage() throws {
        let body = String(decoding: try AuthData(Self.credential).body, as: UTF8.self)
        let keys = body.split(separator: "&").map { $0.split(separator: "=")[0] }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(body.contains("app=com.google.android.apps.photos"))
        XCTAssertTrue(body.contains("callerPkg=com.google.android.apps.photos"))
        XCTAssertTrue(body.contains("Token=aas_et%2Fmaster%2Btoken"))
    }

    // MARK: - Error kinds

    /// The photosdata-pa RPCs are not uniform. gotohp @ 0637c745 sets the two
    /// x-goog-ext headers on commit / CreateAlbum / AddMediaToAlbum but not on
    /// FindRemoteMediaByHash, and Google answers the hash lookup with HTTP 400
    /// when they are present. Observed live on 2026-09-08 as a red step 9.
    func testHashLookupOmitsTheExtensionHeadersThatCommitSends() async throws {
        StubProtocol.handler = { request in
            if request.url?.host == "android.googleapis.com" {
                return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
            }
            return .ok(Data())
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try? await client.validateReadAccess()

        let lookup = StubProtocol.seen.first { $0.url?.absoluteString.hasSuffix("5084965799730810217") == true }
        let request = try XCTUnwrap(lookup, "the hash lookup was never sent")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-ext-173412678-bin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-ext-174067345-bin"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
    }

    /// A refactor once routed every request through a shared `send` helper and
    /// dropped `httpBody` on the way, so each protobuf RPC posted an empty body
    /// and Google answered 400. Nothing caught it: `body` still looked used
    /// because the re-auth retry passes it along. Assert the bytes go out.
    func testRpcActuallySendsItsProtobufBody() async throws {
        StubProtocol.handler = { request in
            if request.url?.host == "android.googleapis.com" {
                return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
            }
            return .ok(Data())
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try? await client.validateReadAccess()

        let lookup = StubProtocol.seen.first { $0.url?.absoluteString.hasSuffix("5084965799730810217") == true }
        let request = try XCTUnwrap(lookup, "the hash lookup was never sent")
        let sent = Self.body(of: request)
        XCTAssertFalse(sent.isEmpty, "the hash lookup posted an empty body")
        // HashCheck { field1 { field1 { sha1Hash } , field2 {} } } — the 20-byte
        // hash has to appear inside it.
        XCTAssertTrue(sent.count >= 20)
    }

    /// URLProtocol sees a streamed body, not `httpBody`, so read whichever is set.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
        }
        return out
    }

    func testRetryClassification() {
        XCTAssertTrue(GPMCError(kind: .transport, message: "x").isRetryable)
        XCTAssertTrue(GPMCError(kind: .server(503), message: "x").isRetryable)
        XCTAssertTrue(GPMCError(kind: .server(429), message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .server(400), message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .credentialRejected, message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .tokenBound, message: "x").isRetryable)
        XCTAssertTrue(GPMCError(kind: .invalidUploadReceipt, message: "x").isRetryable)
    }

    func testGoogleProtobufErrorIsReadableAndTruncatedBinaryStillHasHexFallback() {
        let message = "At least one valid blueprint is required; upload token rejected"
        let status = Proto.int(1, 3) + Proto.string(2, message)
        XCTAssertEqual(GPMCClient.explanation(status), " Google said: " + message)
        XCTAssertEqual(GPMCClient.explanation(status, limit: 12), " Google said: At least one")
        XCTAssertEqual(GPMCClient.explanation(Data(status.prefix(15))),
                       " Google said: 0x" + status.prefix(15).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(GPMCClient.explanation(Data("Unavailable".utf8)), " Google said: Unavailable")
        XCTAssertEqual(GPMCClient.explanation(Data()), "")
    }

    func testInvalidReceiptsAreRejectedBeforeAnyCommitRequestIncludingRestoredReceipts() async throws {
        StubProtocol.handler = Self.photosHandler()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let file = try scratchFile()
        for receipt in [Data(), Proto.int(1, 1), Proto.bytes(2, Data()), Data([0x12, 0x05, 0x01])] {
            let prepared = PreparedUpload(uploadURL: URL(string: "https://example.test/upload")!,
                                          hash: Data(repeating: 1, count: 20), filename: "image.jpg",
                                          modified: Date(), byteCount: 4096, receipt: receipt)
            await XCTAssertThrowsGPMC(kind: .invalidUploadReceipt) {
                _ = try await client.commit(prepared, useQuota: false, saver: false) { _ in }
            }
            await XCTAssertThrowsGPMC(kind: .invalidUploadReceipt) {
                _ = try await client.transfer(prepared, file: file, transferID: UUID()) { _ in }
            }
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    // MARK: - authenticate()

    func testAuthenticateAcceptsAnAuthLine() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        try await client.authenticate()
        let sent = StubProtocol.seen.first
        XCTAssertEqual(sent?.url?.absoluteString, "https://android.googleapis.com/auth")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "app"), "com.google.android.apps.photos")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "device"), "0123456789abcdef")
    }

    func testWiFiOnlyPolicyIsAppliedToEveryRequest() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
        let policy = UploadRequestNetworkPolicy()
        policy.setCellularAllowed(false)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), networkPolicy: policy)

        try await client.authenticate()

        let sent = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertFalse(sent.allowsCellularAccess)
        XCTAssertFalse(sent.allowsExpensiveNetworkAccess)
    }

    func testCellularPolicyCanBeChangedWithoutRecreatingTheClient() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
        let policy = UploadRequestNetworkPolicy()
        policy.setCellularAllowed(false)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), networkPolicy: policy)
        try await client.authenticate()

        policy.setCellularAllowed(true)
        try await client.authenticate()

        XCTAssertEqual(StubProtocol.seen.count, 2)
        XCTAssertFalse(StubProtocol.seen[0].allowsCellularAccess)
        XCTAssertTrue(StubProtocol.seen[1].allowsCellularAccess)
        XCTAssertTrue(StubProtocol.seen[1].allowsExpensiveNetworkAccess)
    }

    func testBoundTokenIsDetectedAndRejectedRatherThanUsed() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nTokenEncrypted=1\nExpiry=\(Self.farFuture)\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .tokenBound) { try await client.authenticate() }
    }

    func testErrorLineOnA200IsACredentialRejectionNotASuccess() async throws {
        StubProtocol.handler = { _ in .text("Error=BadAuthentication\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.authenticate() }
    }

    func testErrorLineOnA403IsReadBeforeTheStatusCode() async throws {
        StubProtocol.handler = { _ in .text("Error=BadAuthentication\nUrl=https://accounts.google.com\n", status: 403) }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.authenticate() }
    }

    func testServerErrorIsRetryableRatherThanACredentialProblem() async throws {
        StubProtocol.handler = { _ in .text("", status: 503) }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .server(503)) { try await client.authenticate() }
    }

    // MARK: - upload()

    /// A scripted Google: auth, hash lookup, upload initiate, PUT, commit.
    private static func photosHandler(existingKey: String? = nil,
                                      committedKey: String = "MEDIAKEY") -> (URLRequest) -> StubProtocol.Reply {
        { request in
            let path = request.stubPath
            if path == "/auth" { return .text("Auth=ya29.token\nExpiry=\(farFuture)\n") }
            if path.hasSuffix("/5084965799730810217") {
                guard let existingKey else { return .ok(Data()) }
                return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, existingKey)))))
            }
            if path.hasSuffix("/16538846908252377752") {
                return .ok(Proto.bytes(1, Proto.bytes(3, Proto.string(1, committedKey))))
            }
            if request.httpMethod == "PUT" { return .ok(Proto.int(1, 1) + Proto.bytes(2, Data("receipt".utf8))) }
            return .ok(Data(), headers: ["X-GUploader-UploadID": "upload-123"])
        }
    }

    private func scratchFile(_ bytes: Int = 4096, name: String = "IMG_0001.JPG") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    func testUploadReportsPhasesInOrderAndReturnsTheCommittedKey() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let phases = PhaseRecorder()
        let outcome = try await client.upload(file: file, filename: "IMG_0001.JPG",
                                              modified: Date(timeIntervalSince1970: 1_600_000_000),
                                              useQuota: false, saver: false) { phases.record($0) }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        let seen = phases.phases
        XCTAssertEqual(seen.first, .hashing(fraction: 0))
        XCTAssertTrue(seen.contains(.hashing(fraction: 1)))
        XCTAssertTrue(seen.contains(.checkingDuplicate))
        XCTAssertTrue(seen.contains(.preparing))
        XCTAssertTrue(seen.contains(.sending(sent: 0, total: 4096)))
        XCTAssertEqual(seen.last, .finalizing)

        // The initiate request must advertise the same SHA-1 and length the
        // hashing pass computed.
        let initiate = StubProtocol.seen.first { $0.httpMethod == "POST" && $0.stubPath.hasSuffix("/interactive") }
        let expected = Data(Insecure.SHA1.hash(data: try Data(contentsOf: file))).base64EncodedString()
        XCTAssertEqual(initiate?.value(forHTTPHeaderField: "X-Goog-Hash"), "sha1=" + expected)
        XCTAssertEqual(initiate?.value(forHTTPHeaderField: "X-Upload-Content-Length"), "4096")

        // Preserve the 0.2.0 commit envelope, including the exact receipt bytes.
        let commit = try XCTUnwrap(StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") })
        let receipt = Proto.int(1, 1) + Proto.bytes(2, Data("receipt".utf8))
        let metadata = Proto.bytes(1, receipt) + Proto.string(2, "IMG_0001.JPG")
            + Proto.bytes(3, Data(base64Encoded: expected)!)
            + Proto.bytes(4, Proto.int(1, 1_600_000_000) + Proto.int(2, 46_000_000))
            + Proto.int(7, 3) + Proto.int(10, 1)
        let device = Proto.string(3, "Pixel XL") + Proto.string(4, "Google") + Proto.int(5, 28)
        XCTAssertEqual(Self.body(of: commit), Proto.bytes(1, metadata) + Proto.bytes(2, device) + Proto.bytes(3, Data([1, 3])))
        XCTAssertEqual(commit.value(forHTTPHeaderField: "x-goog-ext-173412678-bin"), "CgcIAhClARgC")
        XCTAssertEqual(commit.value(forHTTPHeaderField: "x-goog-ext-174067345-bin"), "CgIIAg==")
    }

    @MainActor
    func testBlueprintRejectionRetriesWithFreshPreflightAndForegroundTransfer() async throws {
        let commits = Counter()
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/16538846908252377752") {
                commits.bump()
                let receipt = try? Proto.fields(Self.body(of: request))[1]?.first
                    .flatMap { try Proto.fields($0)[1]?.first }
                let token = receipt.flatMap { try? Proto.string(at: [2], in: $0) }
                if commits.value == 1 {
                    XCTAssertEqual(token, "background-receipt")
                    return StubProtocol.Reply(status: 400, body: Proto.int(1, 3)
                        + Proto.string(2, "At least one valid blueprint is required; upload token rejected"))
                }
                XCTAssertEqual(token, "receipt", "the rejected receipt must never be replayed")
            }
            return handler(request)
        }
        let transport = RecordingFileUploadTransport()
        let policy = UploadRequestNetworkPolicy()
        policy.setCellularAllowed(false)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(),
                                    networkPolicy: policy, fileUploadTransport: transport)
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        let queue = UploadQueue(worker: worker, maxAttempts: 3, sleeper: { _ in await Task.yield() })
        queue.enqueue([.file(try scratchFile())])
        let deadline = Date().addingTimeInterval(5)
        while !queue.isIdle, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(queue.items.first?.attempts, 2)
        XCTAssertEqual(commits.value, 2)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(StubProtocol.seen.filter { $0.stubPath.hasSuffix("/5084965799730810217") }.count, 2)
        XCTAssertEqual(StubProtocol.seen.filter { $0.httpMethod == "POST" && $0.stubPath.hasSuffix("/interactive") }.count, 2)
        let put = try XCTUnwrap(StubProtocol.seen.first { $0.httpMethod == "PUT" })
        XCTAssertFalse(put.allowsCellularAccess)
        XCTAssertFalse(put.allowsExpensiveNetworkAccess)
    }

    func testEmptyBackgroundReceiptPersistsForegroundRecoveryAcrossRelaunch() async throws {
        StubProtocol.handler = Self.photosHandler()
        let transport = RecordingFileUploadTransport(receipt: Data())
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), fileUploadTransport: transport)
        let file = try scratchFile()
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        let recorder = CheckpointRecorder()
        let id = UUID()
        await XCTAssertThrowsGPMC(kind: .invalidUploadReceipt) {
            _ = try await worker(id, .file(file), nil, UploadOptions()) { recorder.record($0) }
        }
        let saved = try XCTUnwrap(recorder.checkpoint)
        XCTAssertNil(saved.prepared)
        XCTAssertEqual(saved.continuesAfterProcessExit, false)
        XCTAssertFalse(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/16538846908252377752") })
        let restored = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(saved))
        let relaunched = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), fileUploadTransport: transport)
        let resumedWorker = PhotosUploader(exporter: MediaExporter()) { relaunched }.worker()
        let outcome = try await resumedWorker(id, .file(file), restored, UploadOptions()) { recorder.record($0) }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        XCTAssertEqual(transport.requests.count, 1, "relaunch must honor the saved transport fallback")
        XCTAssertEqual(StubProtocol.seen.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    /// Any other canonical code on the commit call is a real rejection of the
    /// upload, not of the receipt, and nothing about it is worth retrying.
    func testUnrelatedStatusCodeOnCommitDoesNotTriggerReceiptRecovery() async throws {
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/16538846908252377752") {
                return StubProtocol.Reply(status: 400, body: Proto.int(1, 9) + Proto.string(2, "Invalid metadata"))
            }
            return handler(request)
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let file = try scratchFile()
        do {
            _ = try await client.upload(file: file, filename: "image.jpg", useQuota: false, saver: false) { _ in }
            XCTFail("expected rejection")
        } catch let error as GPMCError {
            XCTAssertEqual(error.kind, .server(400))
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.status?.code, .failedPrecondition)
            XCTAssertTrue(error.message.contains("during finalization"))
            XCTAssertTrue(error.message.contains("Invalid metadata"))
            XCTAssertFalse(error.message.contains("Check your connection"))
        }
    }

    /// The canonical code is the signal, not Google's prose: the same rejection
    /// worded differently has to be recognised the same way. The message check
    /// is only there for a rejection that carries no parseable status.
    func testReceiptRejectionIsRecognisedByCodeAndByMessageWithoutOne() async throws {
        let bodies: [Data] = [
            Proto.int(1, 3) + Proto.string(2, "Upload token is no longer valid"),
            Data("At least one valid blueprint is required".utf8),
        ]
        for body in bodies {
            let handler = Self.photosHandler()
            StubProtocol.handler = { request in
                request.stubPath.hasSuffix("/16538846908252377752")
                    ? StubProtocol.Reply(status: 400, body: body)
                    : handler(request)
            }
            let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
            await XCTAssertThrowsGPMC(kind: .invalidUploadReceipt) {
                _ = try await client.upload(file: try self.scratchFile(), filename: "image.jpg",
                                            useQuota: false, saver: false) { _ in }
            }
        }
    }

    /// `google.rpc.Status` says more than the HTTP status does. RESOURCE_EXHAUSTED
    /// is a full account, which no amount of retrying will empty; the same code
    /// under a 429 is rate limiting, which is exactly what retrying is for.
    func testStatusCodeDecidesTheKindWhereTheHTTPStatusCannot() async throws {
        let cases: [(Int, Data, GPMCError.Kind, Bool)] = [
            (400, Proto.int(1, 8) + Proto.string(2, "Quota exceeded"), .storageFull, false),
            (429, Proto.int(1, 8) + Proto.string(2, "Too many requests"), .server(429), true),
            (400, Proto.int(1, 16) + Proto.string(2, "Request had invalid authentication"),
             .credentialRejected, false),
        ]
        for (status, body, kind, retryable) in cases {
            StubProtocol.handler = { request in
                request.stubPath == "/auth"
                    ? .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
                    : StubProtocol.Reply(status: status, body: body)
            }
            let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
            do {
                try await client.validateReadAccess()
                XCTFail("expected a rejection for \(kind)")
            } catch let error as GPMCError {
                XCTAssertEqual(error.kind, kind)
                XCTAssertEqual(error.isRetryable, retryable)
                XCTAssertEqual(error.status?.rawCode, status == 429 ? 8 : (kind == .storageFull ? 8 : 16))
            }
        }
    }

    /// The storage message has to say what to do about it, and still carry what
    /// Google said — support cannot act on "HTTP 400" alone.
    func testAFullAccountExplainsItselfAndIsNotRetried() async throws {
        StubProtocol.handler = { request in
            request.stubPath == "/auth"
                ? .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
                : StubProtocol.Reply(status: 400,
                                     body: Proto.int(1, 8) + Proto.string(2, "Quota exceeded for the account"))
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        do {
            try await client.validateReadAccess()
            XCTFail("expected a rejection")
        } catch let error as GPMCError {
            XCTAssertEqual(error.kind, .storageFull)
            XCTAssertTrue(error.message.contains("out of storage"))
            XCTAssertTrue(error.message.contains("Quota exceeded for the account"))
        }
    }

    /// A status is only a status when it parses. Bodies that are not protobuf,
    /// carry no code, or say OK have to stay unclassified rather than being
    /// read as some arbitrary code.
    func testOnlyRealStatusBodiesAreReadAsOne() {
        XCTAssertEqual(GoogleStatus(Proto.int(1, 8) + Proto.string(2, "Quota exceeded"))?.code, .resourceExhausted)
        XCTAssertEqual(GoogleStatus(Proto.string(2, "message first") + Proto.int(1, 3))?.code, .invalidArgument,
                       "field order is not guaranteed on the wire")
        XCTAssertEqual(GoogleStatus(Proto.int(1, 77))?.rawCode, 77)
        XCTAssertNil(GoogleStatus(Proto.int(1, 77))?.code, "an unmapped code changes nothing")
        XCTAssertNil(GoogleStatus(Proto.int(1, 0) + Proto.string(2, "OK")), "code 0 is not a failure")
        XCTAssertNil(GoogleStatus(Data("Service Unavailable".utf8)))
        XCTAssertNil(GoogleStatus(Data()))
        XCTAssertNil(GoogleStatus(Proto.string(2, "no code here")))
    }

    func testVarintFieldsAreReadableAndMalformedBodiesThrow() throws {
        let body = Proto.int(1, 8) + Proto.string(2, "text") + Proto.int(3, 300)
        XCTAssertEqual(try Proto.number(1, in: body), 8)
        XCTAssertEqual(try Proto.number(3, in: body), 300)
        XCTAssertNil(try Proto.number(2, in: body), "a length-delimited field is not a varint")
        XCTAssertNil(try Proto.number(9, in: body))
        // Truncated length prefix: the reader must refuse rather than invent a value.
        XCTAssertThrowsError(try Proto.number(1, in: Data(body.prefix(4))))
        // The length-delimited reader still sees what it always did.
        XCTAssertEqual(try Proto.fields(body)[2]?.first, Data("text".utf8))
    }

    @MainActor
    func testTemporaryCommitFailureReusesReceiptWithoutTransferringAgain() async throws {
        let commits = Counter()
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/16538846908252377752") {
                commits.bump()
                if commits.value == 1 { return .text("Unavailable", status: 503) }
            }
            return handler(request)
        }
        let transport = RecordingFileUploadTransport()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), fileUploadTransport: transport)
        let queue = UploadQueue(worker: PhotosUploader(exporter: MediaExporter()) { client }.worker(),
                                maxAttempts: 3, sleeper: { _ in await Task.yield() })
        queue.enqueue([.file(try scratchFile())])
        let deadline = Date().addingTimeInterval(5)
        while !queue.isIdle, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(commits.value, 2)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(StubProtocol.seen.contains { $0.httpMethod == "PUT" })
        XCTAssertEqual(StubProtocol.seen.filter { $0.stubPath.hasSuffix("/5084965799730810217") }.count, 1)
    }

    /// Recovery is worth one fresh transfer, not the item's whole retry budget:
    /// a rejection that survives a new receipt is not about the receipt.
    @MainActor
    func testPersistentReceiptRejectionCostsOneExtraTransferThenFails() async throws {
        let commits = Counter()
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/16538846908252377752") {
                commits.bump()
                return StubProtocol.Reply(status: 400, body: Proto.int(1, 3)
                    + Proto.string(2, "At least one valid blueprint is required"))
            }
            return handler(request)
        }
        let transport = RecordingFileUploadTransport()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(), fileUploadTransport: transport)
        let queue = UploadQueue(worker: PhotosUploader(exporter: MediaExporter()) { client }.worker(),
                                maxAttempts: 3, sleeper: { _ in await Task.yield() })
        queue.enqueue([.file(try scratchFile())])
        let deadline = Date().addingTimeInterval(5)
        while !queue.isIdle, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        guard case .failed(let reason, let retryable) = queue.items.first?.state else {
            return XCTFail("expected a bounded failure")
        }
        XCTAssertFalse(retryable)
        XCTAssertTrue(reason.contains("At least one valid blueprint is required"),
                      "the reason has to survive the reclassification: \(reason)")
        XCTAssertEqual(queue.items.first?.attempts, 2)
        XCTAssertEqual(commits.value, 2)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(StubProtocol.seen.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testOnlyTheFilePutUsesTheInjectedTransportSeam() async throws {
        StubProtocol.handler = Self.photosHandler()
        let transport = RecordingFileUploadTransport()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session(),
                                    fileUploadTransport: transport)

        let outcome = try await client.upload(file: try scratchFile(), filename: "IMG_0003.JPG",
                                              useQuota: false, saver: false) { _ in }

        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.httpMethod, "PUT")
        XCTAssertFalse(StubProtocol.seen.contains { $0.httpMethod == "PUT" })
        XCTAssertTrue(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/5084965799730810217") })
        XCTAssertTrue(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/16538846908252377752") })
    }

    func testAlreadyBackedUpIsDistinguishableFromAFreshUpload() async throws {
        StubProtocol.handler = Self.photosHandler(existingKey: "EXISTING")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let phases = PhaseRecorder()
        let outcome = try await client.upload(file: try scratchFile(), filename: "IMG_0002.JPG",
                                              useQuota: false, saver: false) { phases.record($0) }
        XCTAssertEqual(outcome, .alreadyBackedUp(mediaKey: "EXISTING"))
        // A duplicate never reaches the transfer phases.
        XCTAssertFalse(phases.phases.contains { if case .sending = $0 { return true }; return false })
    }

    /// Re-upload has to reach the transfer even for bytes Google already holds,
    /// so it never asks for the existing copy.
    func testSkippingTheDuplicateCheckPreparesAnUploadForBytesGoogleHolds() async throws {
        StubProtocol.handler = Self.photosHandler(existingKey: "EXISTING")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let preparation = try await client.prepareUpload(file: try scratchFile(), filename: "IMG_0002.JPG",
                                                         skippingDuplicateCheck: true) { _ in }
        guard case .ready = preparation else { return XCTFail("expected an upload, got \(preparation)") }
        XCTAssertFalse(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/5084965799730810217") })
    }

    func testEmptyFileIsRefusedBeforeAnyRequest() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile(0, name: "empty.jpg")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        do {
            _ = try await client.upload(file: file, filename: "empty.jpg", useQuota: false, saver: false) { _ in }
            XCTFail("expected an empty file to be refused")
        } catch let error as GPMCError {
            XCTAssertTrue(error.message.contains("empty"))
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testCancellationSurfacesAsCancellationErrorNotATransportFailure() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile(8 * 1_048_576)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let task = Task {
            try await client.upload(file: file, filename: "big.jpg", useQuota: false, saver: false) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the upload to be cancelled")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testMidFlightRejectionIsRetriedOnceWithAFreshTokenThenGivenUpOn() async throws {
        // Every RPC answers 401. The client should re-authenticate once and try
        // again before reporting the credential as rejected.
        let counter = Counter()
        StubProtocol.handler = { request in
            if request.stubPath == "/auth" { return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
            counter.bump()
            return .text("", status: 401)
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.validateReadAccess() }
        XCTAssertEqual(counter.value, 2, "the RPC should be attempted twice, once per token")
        XCTAssertEqual(StubProtocol.seen.filter { $0.stubPath == "/auth" }.count, 2)
    }

    // MARK: - Commit policy

    /// `Proto.fields` returns only length-delimited fields, and the storage
    /// policy is a varint inside a submessage, so walk the wire format here.
    static func varint(_ field: Int, in data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        var index = 0
        func read() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = read() else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = read() else { return nil }
                if number == field { return value }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = read(), index + Int(length) <= bytes.count else { return nil }
                index += Int(length)
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Live Photo motion

    /// A scripted Google for a motion upload. `motionKey` answers the lookup
    /// made as a Live Photo motion (sha1MediaType 2), `stillKey` the plain one.
    private static func motionHandler(motionKey: String?, stillKey: String?) -> (URLRequest) -> StubProtocol.Reply {
        { request in
            let path = request.stubPath
            if path == "/auth" { return .text("Auth=ya29.token\nExpiry=\(farFuture)\n") }
            if path.hasSuffix("/5084965799730810217") {
                let key = isMotionLookup(request) ? motionKey : stillKey
                guard let key else { return .ok(Data()) }
                return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, key)))))
            }
            if path.hasSuffix("/16538846908252377752") {
                return .ok(Proto.bytes(1, Proto.bytes(3, Proto.string(1, stillKey ?? "NEWKEY"))))
            }
            if request.httpMethod == "PUT" { return .ok(Proto.int(1, 1) + Proto.bytes(2, Data("receipt".utf8))) }
            return .ok(Data(), headers: ["X-GUploader-UploadID": "upload-123"])
        }
    }

    /// `request.queryArray[0].sha1MediaType == PhodeoMovie (2)`.
    private static func isMotionLookup(_ request: URLRequest) -> Bool {
        guard let lookup = try? Proto.fields(body(of: request))[1]?.first,
              let query = try? Proto.fields(lookup)[1]?.first else { return false }
        return (try? Proto.number(5, in: query)) == 2
    }

    /// The Google Photos app's own check for attached motion: the video's hash,
    /// looked up as a Live Photo motion, resolves to the Live Photo. Nothing is
    /// uploaded when it does.
    func testMotionAlreadyAttachedSettlesWithoutUploading() async throws {
        StubProtocol.handler = Self.motionHandler(motionKey: "LIVEKEY", stillKey: "STILLKEY")
        let file = try scratchFile(name: "IMG_0001.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let preparation = try await client.prepareMotionUpload(file: file, filename: "IMG_0001.MOV",
                                                               stillHash: Data(repeating: 1, count: 20)) { _ in }
        XCTAssertEqual(preparation, .alreadyBackedUp(mediaKey: "LIVEKEY"))
        let lookups = StubProtocol.seen.filter { $0.stubPath.hasSuffix("/5084965799730810217") }
        XCTAssertEqual(lookups.count, 1)
        XCTAssertTrue(Self.isMotionLookup(try XCTUnwrap(lookups.first)))
        XCTAssertFalse(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/interactive") })
    }

    /// The motion is committed onto its still, so without the still in the
    /// account there is nothing to attach it to yet: wait and retry, don't upload.
    func testMotionWaitsWhileItsPhotoIsNotInTheAccount() async throws {
        StubProtocol.handler = Self.motionHandler(motionKey: nil, stillKey: nil)
        let file = try scratchFile(name: "IMG_0001.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        do {
            _ = try await client.prepareMotionUpload(file: file, filename: "IMG_0001.MOV",
                                                     stillHash: Data(repeating: 1, count: 20)) { _ in }
            XCTFail("expected the motion to wait for its photo")
        } catch let error as GPMCError {
            XCTAssertEqual(error.kind, .pairedPhotoMissing)
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertFalse(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/interactive") })
    }

    func testMotionUploadsWhenItsPhotoIsInTheAccountWithoutIt() async throws {
        StubProtocol.handler = Self.motionHandler(motionKey: nil, stillKey: "STILLKEY")
        let file = try scratchFile(name: "IMG_0001.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let preparation = try await client.prepareMotionUpload(file: file, filename: "IMG_0001.MOV",
                                                               stillHash: Data(repeating: 1, count: 20)) { _ in }
        guard case .ready(let prepared) = preparation else { return XCTFail("expected an upload, got \(preparation)") }
        XCTAssertEqual(prepared.hash, Data(Insecure.SHA1.hash(data: try Data(contentsOf: file))))
        XCTAssertEqual(prepared.filename, "IMG_0001.MOV")
    }

    /// The seam between the two halves: a restored motion checkpoint goes
    /// through the motion preflight, and its still's hash reaches the commit.
    func testAMotionCheckpointIsPreparedAsMotionAndCommittedOntoItsStill() async throws {
        StubProtocol.handler = Self.motionHandler(motionKey: nil, stillKey: "STILLKEY")
        let file = try scratchFile(name: "IMG_0001.MOV")
        let stillHash = Data(repeating: 5, count: 20)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        let checkpoint = UploadCheckpoint(filePath: file.path, filename: "IMG_0001.MOV",
                                          modified: Date(timeIntervalSince1970: 1_600_000_000), byteCount: 4096,
                                          temporary: false, prepared: nil, continuesAfterProcessExit: false,
                                          pairedStillHash: stillHash)
        let outcome = try await worker(UUID(), .livePhotoMotion(localIdentifier: "live-1"), checkpoint,
                                       UploadOptions()) { _ in }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "STILLKEY"))
        XCTAssertTrue(StubProtocol.seen.contains { $0.stubPath.hasSuffix("/5084965799730810217") && Self.isMotionLookup($0) })
        let commit = try XCTUnwrap(StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") })
        let metadata = try XCTUnwrap(try Proto.fields(Self.body(of: commit))[1]?.first)
        XCTAssertEqual(try Proto.fields(metadata)[9]?.first, Proto.int(2, 1) + Proto.bytes(3, stillHash))
    }

    /// Blueprint field 9 `reconcileInfo {2: Phodeo, 3: still SHA-1}` is what
    /// attaches the upload to the still as its motion (verified on device,
    /// 2026-09-19: the item plays as a Live Photo and stays free).
    func testMotionCommitNamesTheStillItAttachesTo() async throws {
        let stillHash = Data(repeating: 9, count: 20)
        StubProtocol.handler = Self.photosHandler()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try await client.commit(Self.preparedFixture(), useQuota: false, saver: false,
                                    pairedStillHash: stillHash) { _ in }
        let sent = try XCTUnwrap(StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") })
        let metadata = try XCTUnwrap(try Proto.fields(Self.body(of: sent))[1]?.first)
        XCTAssertEqual(try Proto.fields(metadata)[9]?.first, Proto.int(2, 1) + Proto.bytes(3, stillHash))
        XCTAssertEqual(Self.varint(7, in: metadata), 3)
    }

    func testAPlainCommitAttachesNothing() async throws {
        let (metadata, _) = try await commitBody(Self.preparedFixture(), useQuota: false, saver: false)
        XCTAssertNil(try Proto.fields(metadata)[9])
    }

    private static func preparedFixture() -> PreparedUpload {
        PreparedUpload(uploadURL: URL(string: "https://example.com/upload")!,
                       hash: Data(repeating: 7, count: 20), filename: "IMG_0009.JPG",
                       modified: Date(timeIntervalSince1970: 1_600_000_000), byteCount: 4096,
                       // Field 2 is where Google puts the upload token; a
                       // receipt without it no longer reaches the wire.
                       receipt: Proto.string(2, "receipt"))
    }

    /// Commit `prepared` under the given settings and return the two
    /// submessages of the body that actually went out: the item metadata and
    /// the spoofed upload device.
    private func commitBody(_ prepared: PreparedUpload, useQuota: Bool,
                            saver: Bool) async throws -> (metadata: Data, device: Data) {
        StubProtocol.handler = Self.photosHandler()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try await client.commit(prepared, useQuota: useQuota, saver: saver) { _ in }
        let sent = StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") }
        let fields = try Proto.fields(Self.body(of: try XCTUnwrap(sent, "the commit RPC was never sent")))
        return (try XCTUnwrap(fields[1]?.first, "no item metadata"),
                try XCTUnwrap(fields[2]?.first, "no upload device"))
    }

    /// Storage policy 3 against the device that carries the original-quality
    /// exemption. Nothing asserted these bytes before, and they are the entire
    /// difference between an original-quality and a Storage Saver upload.
    func testCommitAsksForOriginalQualityWhenStorageSaverIsOff() async throws {
        let (metadata, device) = try await commitBody(Self.preparedFixture(), useQuota: false, saver: false)
        XCTAssertEqual(Self.varint(7, in: metadata), 3)
        XCTAssertTrue(String(decoding: device, as: UTF8.self).contains("Pixel XL"))
    }

    func testCommitAsksForStorageSaverWhenTheToggleIsOn() async throws {
        let (metadata, device) = try await commitBody(Self.preparedFixture(), useQuota: false, saver: true)
        XCTAssertEqual(Self.varint(7, in: metadata), 1)
        XCTAssertTrue(String(decoding: device, as: UTF8.self).contains("Pixel 2"))
    }

    /// Counting against quota only swaps the device; it must not quietly ask
    /// for Storage Saver on the user's behalf.
    func testCountingAgainstQuotaSwapsTheDeviceButKeepsOriginalQuality() async throws {
        let (metadata, device) = try await commitBody(Self.preparedFixture(), useQuota: true, saver: false)
        XCTAssertEqual(Self.varint(7, in: metadata), 3)
        XCTAssertTrue(String(decoding: device, as: UTF8.self).contains("Pixel 8"))
    }

    /// The regression. One prepared upload, committed twice under opposite
    /// settings: a checkpoint can outlive the toggle it was made under, so the
    /// policy has to come from the call and not from the persisted value.
    func testCommitPolicyFollowsCurrentSettingsNotThePreparedCheckpoint() async throws {
        let prepared = Self.preparedFixture()
        let asSaver = try await commitBody(prepared, useQuota: false, saver: true)
        let asOriginal = try await commitBody(prepared, useQuota: false, saver: false)
        XCTAssertEqual(Self.varint(7, in: asSaver.metadata), 1)
        XCTAssertEqual(Self.varint(7, in: asOriginal.metadata), 3)
        XCTAssertTrue(String(decoding: asSaver.device, as: UTF8.self).contains("Pixel 2"))
        XCTAssertTrue(String(decoding: asOriginal.device, as: UTF8.self).contains("Pixel XL"))
    }

}

// MARK: - Helpers

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UploadCheckpoint?
    func record(_ event: UploadEvent) {
        guard case .checkpoint(let checkpoint) = event else { return }
        lock.lock(); storage = checkpoint; lock.unlock()
    }
    var checkpoint: UploadCheckpoint? { lock.lock(); defer { lock.unlock() }; return storage }
}

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UploadPhase] = []
    func record(_ phase: UploadPhase) { lock.lock(); storage.append(phase); lock.unlock() }
    var phases: [UploadPhase] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

func XCTAssertThrowsGPMC(kind: GPMCError.Kind, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected a GPMCError(\(kind))", file: file, line: line)
    } catch let error as GPMCError {
        XCTAssertEqual(error.kind, kind, error.message, file: file, line: line)
    } catch {
        XCTFail("expected a GPMCError(\(kind)), got \(error)", file: file, line: line)
    }
}
