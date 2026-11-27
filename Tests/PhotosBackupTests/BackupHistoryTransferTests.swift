import XCTest
@testable import PhotosBackup

final class BackupHistoryTransferTests: XCTestCase {

    func testArchiveRoundTripsAndDeduplicatesKeys() throws {
        let archive = BackupHistoryArchive(
            completedSourceKeys: ["asset:b", "asset:a", "asset:b", "motion:a"],
            googleAlbums: ["Vacation": "AF1QipAlbum1"],
            exportedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
        let data = try archive.encode()
        let decoded = try BackupHistoryArchive.decode(data)
        XCTAssertEqual(decoded.version, BackupHistoryArchive.currentVersion)
        XCTAssertEqual(decoded.completedSourceKeys, ["asset:a", "asset:b", "motion:a"])
        XCTAssertEqual(decoded.googleAlbums, ["Vacation": "AF1QipAlbum1"])
    }

    func testArchiveRejectsUnsupportedVersionAndInvalidJSON() throws {
        let future = BackupHistoryArchive(completedSourceKeys: ["asset:1"], version: 99)
        let data = try future.encode()
        XCTAssertThrowsError(try BackupHistoryArchive.decode(data)) { error in
            XCTAssertEqual(error as? BackupHistoryArchive.Failure, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try BackupHistoryArchive.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? BackupHistoryArchive.Failure, .invalidFormat)
        }
    }

    @MainActor
    func testImportingHistoryPersistsToLedgerAndDropsMatchingQueuedRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileUploadQueuePersistence(url: directory.appendingPathComponent("queue.json"))

        let queue = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        queue.activateAccount("person@gmail.com")
        queue.enqueue([.asset(localIdentifier: "a1"), .asset(localIdentifier: "a2")], skippingExisting: true)
        XCTAssertEqual(queue.items.count, 2)

        let imported = queue.importCompletedSourceKeys(["asset:a1", "asset:a3", "asset:a1", ""])
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(queue.items.map(\.source), [.asset(localIdentifier: "a2")])
        XCTAssertEqual(queue.completedSourceCount, 2)

        // Re-importing the same keys adds nothing.
        XCTAssertEqual(queue.importCompletedSourceKeys(["asset:a1", "asset:a3"]), 0)

        // Survives relaunch.
        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertTrue(restored.completedSourceKeys.contains("asset:a1"))
        XCTAssertTrue(restored.completedSourceKeys.contains("asset:a3"))
        XCTAssertEqual(restored.items.map(\.source), [.asset(localIdentifier: "a2")])
    }

    func testAlbumRegistryMergeAddsNewAlbumsWithoutOverwritingExisting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = GoogleAlbumRegistry(directory: directory)
        try registry.save("EXISTING_KEY", named: "Trip", for: "person@gmail.com")

        let added = try registry.merge(["Trip": "OTHER_KEY", "Family": "FAMILY_KEY"], for: "person@gmail.com")
        XCTAssertEqual(added, 1)
        XCTAssertEqual(registry.albumKey(named: "Trip", for: "person@gmail.com"), "EXISTING_KEY")
        XCTAssertEqual(registry.albumKey(named: "Family", for: "person@gmail.com"), "FAMILY_KEY")
    }
}
