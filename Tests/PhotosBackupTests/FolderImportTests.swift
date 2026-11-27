import XCTest
@testable import PhotosBackup

final class FolderImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func write(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: url)
    }

    func testPlaceholderNamesResolveAndOtherHiddenFilesDoNot() {
        XCTAssertEqual(FolderScanner.placeholderName(".IMG_0001.HEIC.icloud"), "IMG_0001.HEIC")
        XCTAssertNil(FolderScanner.placeholderName(".DS_Store"))
        XCTAssertNil(FolderScanner.placeholderName("IMG_0001.HEIC"))
    }

    func testOnlyPhotosAndVideosCountAsMedia() {
        XCTAssertTrue(FolderScanner.isMedia("IMG_0001.HEIC"))
        XCTAssertTrue(FolderScanner.isMedia("clip.mov"))
        XCTAssertTrue(FolderScanner.isMedia("photo.jpg"))
        XCTAssertFalse(FolderScanner.isMedia("notes.txt"))
        XCTAssertFalse(FolderScanner.isMedia("README"))
    }

    /// Recursive, media only, hidden folders skipped, iCloud placeholders kept
    /// under their real names, and every path relative to the picked folder.
    func testScanListsMediaRecursivelyRelativeToThePickedFolder() throws {
        let picked = directory.appendingPathComponent("Trip", isDirectory: true)
        try write("a.jpg", in: picked)
        try write("Day 1/b.mov", in: picked)
        try write("Day 1/notes.txt", in: picked)
        try write("Day 1/.c.HEIC.icloud", in: picked)
        try write(".hidden/d.jpg", in: picked)
        let store = PickedFolderStore(url: directory.appendingPathComponent("folders.json"))

        let sources = try FolderScanner.sources(inPickedFolder: picked, store: store)

        let paths = sources.compactMap { source -> String? in
            guard case .folderFile(_, let path) = source else { return nil }
            return path
        }
        XCTAssertEqual(paths, ["Day 1/b.mov", "Day 1/c.HEIC", "a.jpg"])
    }

    /// The desktop rule: a file's album is its parent folder; a file at the top
    /// of the picked folder goes into an album named after the picked folder.
    func testAlbumNameIsTheParentFolder() throws {
        let picked = directory.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let store = PickedFolderStore(url: directory.appendingPathComponent("folders.json"))
        let id = try store.register(picked)
        XCTAssertEqual(store.albumName(folderID: id, relativePath: "a.jpg"), "Trip")
        XCTAssertEqual(store.albumName(folderID: id, relativePath: "Day 1/b.mov"), "Day 1")
    }

    /// Re-picking a folder keeps its id, so its items keep their dedup keys,
    /// and the record survives a relaunch.
    func testPickingTheSameFolderAgainReusesItsIdAcrossRelaunch() throws {
        let picked = directory.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("folders.json")
        let first = try PickedFolderStore(url: file).register(picked)
        let relaunched = PickedFolderStore(url: file)
        XCTAssertEqual(try relaunched.register(picked), first)
        XCTAssertEqual(relaunched.folder(first)?.name, "Trip")
    }

    func testFolderFilesSurviveTheQueueSnapshot() throws {
        let source = MediaSource.folderFile(folderID: "F", relativePath: "Day 1/b.mov")
        let persisted = try XCTUnwrap(PersistedMediaSource(source))
        let decoded = try JSONDecoder().decode(PersistedMediaSource.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded.mediaSource, source)
    }

    func testExportCopiesAFolderFileIntoStaging() async throws {
        let picked = directory.appendingPathComponent("Trip", isDirectory: true)
        try write("Day 1/b.mov", in: picked)
        let store = PickedFolderStore(url: directory.appendingPathComponent("folders.json"))
        let id = try store.register(picked)
        let exporter = MediaExporter(folders: store)

        let media = try await exporter.export(.folderFile(folderID: id, relativePath: "Day 1/b.mov"))
        defer { Task { await exporter.discard(media) } }

        XCTAssertTrue(media.temporary)
        XCTAssertEqual(media.filename, "b.mov")
        XCTAssertEqual(try Data(contentsOf: media.url), Data("bytes".utf8))
        XCTAssertNotEqual(media.url.deletingLastPathComponent(), picked.appendingPathComponent("Day 1"))
    }

    func testAFileGoneFromItsFolderReadsAsMissing() async throws {
        let picked = directory.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let store = PickedFolderStore(url: directory.appendingPathComponent("folders.json"))
        let id = try store.register(picked)
        do {
            _ = try await MediaExporter(folders: store).export(.folderFile(folderID: id, relativePath: "gone.jpg"))
            XCTFail("expected missingAsset")
        } catch {
            XCTAssertEqual(error as? MediaExporter.Failure, .missingAsset)
        }
    }
}
