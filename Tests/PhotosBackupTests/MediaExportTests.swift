import Photos
import XCTest
@testable import PhotosBackup

/// Only the file-backed paths are exercised here — the `PHAsset` and
/// `PhotosPickerItem` paths need a real photo library and a user tap, so they
/// stay out of the offline suite.
final class MediaExportTests: XCTestCase {

    private func scratch(_ contents: Data, named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// The Google Photos app only counts a photo on the iPhone as backed up when
    /// the account holds the file it would upload itself — the rendered edit for
    /// an edited asset. Observed on device on 2026-09-18: an edited Live Photo
    /// backed up as its original never counted; as its rendered edit, it did.
    func testAnEditedAssetUploadsItsRenderedEditBeforeTheOriginal() {
        XCTAssertEqual(MediaExporter.uploadResourceTypes(for: .image, edited: true), [.fullSizePhoto, .photo])
        XCTAssertEqual(MediaExporter.uploadResourceTypes(for: .image, edited: false), [.photo, .fullSizePhoto])
        XCTAssertEqual(MediaExporter.uploadResourceTypes(for: .video, edited: true), [.fullSizeVideo, .video])
        XCTAssertEqual(MediaExporter.uploadResourceTypes(for: .video, edited: false), [.video, .fullSizeVideo])

        for type in [PHAssetMediaType.image, .video, .unknown] {
            for edited in [true, false] {
                let types = MediaExporter.uploadResourceTypes(for: type, edited: edited)
                XCTAssertFalse(types.contains(.pairedVideo), "Live Photo motion is not uploaded")
                XCTAssertFalse(types.contains(.fullSizePairedVideo), "Live Photo motion is not uploaded")
            }
        }
    }

    /// An edited video keeps a rendered still beside its rendered video. Seen on
    /// device on 2026-09-19: an edited-first list shared by photos and videos
    /// uploaded that still as "IMG_0116.JPG" in place of the video.
    func testAnEditedVideoNeverUploadsTheStillKeptBesideIt() {
        XCTAssertFalse(MediaExporter.uploadResourceTypes(for: .video, edited: true).contains(.fullSizePhoto))
        XCTAssertFalse(MediaExporter.uploadResourceTypes(for: .video, edited: false).contains(.fullSizePhoto))
        XCTAssertFalse(MediaExporter.uploadResourceTypes(for: .image, edited: true).contains(.fullSizeVideo))
    }

    /// The motion attached is the video that matches the still: the rendered
    /// edit's video for an edited Live Photo, as the Google Photos app attaches it.
    func testALivePhotoMotionIsThePairedVideoOfTheSameVersion() {
        XCTAssertEqual(MediaExporter.motionResourceTypes(edited: false), [.pairedVideo])
        XCTAssertEqual(MediaExporter.motionResourceTypes(edited: true).first, .fullSizePairedVideo)
    }

    /// PhotoKit shows one frame of a burst unless asked. Seen on device on
    /// 2026-11-16: the hidden frame of a two-frame burst was never queued, and
    /// the Google Photos app called the burst not backed up.
    func testLibraryReadsIncludeEveryBurstFrame() {
        XCTAssertTrue(PHFetchOptions.includingBurstFrames.includeAllBurstAssets)
        XCTAssertTrue(PhotoAlbumStore.allPhotosOptions().includeAllBurstAssets)
    }

    func testARenderedEditIsUploadedUnderTheOriginalName() {
        XCTAssertEqual(MediaExporter.uploadFilename(original: "IMG_0351.HEIC", rendition: "FullSizeRender.heic"), "IMG_0351.HEIC")
        XCTAssertEqual(MediaExporter.uploadFilename(original: "IMG_0007.PNG", rendition: "FullSizeRender.heic"), "IMG_0007.HEIC")
        XCTAssertEqual(MediaExporter.uploadFilename(original: "clip.mov", rendition: "FullSizeRender.mp4"), "clip.mp4")
        XCTAssertEqual(MediaExporter.uploadFilename(original: "IMG_4242.HEIC", rendition: "IMG_4242.HEIC"), "IMG_4242.HEIC")
        XCTAssertEqual(MediaExporter.uploadFilename(original: nil, rendition: "FullSizeRender.jpg"), "FullSizeRender.jpg")
    }

    func testExportingAnExistingFileKeepsItsNameSizeAndDate() async throws {
        let url = try scratch(Data(repeating: 7, count: 2048), named: "IMG_4242.HEIC")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let media = try await MediaExporter().export(.file(url))
        XCTAssertEqual(media.filename, "IMG_4242.HEIC")
        XCTAssertEqual(media.byteCount, 2048)
        XCTAssertEqual(media.modified.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(media.temporary, "a file we did not stage is not ours to delete")
    }

    func testDiscardNeverDeletesAFileTheExporterDoesNotOwn() async throws {
        let url = try scratch(Data(repeating: 1, count: 16), named: "keep.jpg")
        let exporter = MediaExporter()
        let media = try await exporter.export(.file(url))
        await exporter.discard(media)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnEmptyFileIsRefusedBeforeItReachesTheUploader() async throws {
        let url = try scratch(Data(), named: "empty.jpg")
        do {
            _ = try await MediaExporter().export(.file(url))
            XCTFail("expected an empty file to be refused")
        } catch let failure as MediaExporter.Failure {
            XCTAssertEqual(failure, .unreadable("the file is empty"))
        }
    }

    func testMissingFileFailsWithAReadableMessage() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID()).jpg")
        do {
            _ = try await MediaExporter().export(.file(missing))
            XCTFail("expected a missing file to be refused")
        } catch let failure as MediaExporter.Failure {
            XCTAssertEqual(failure, .unreadable("the file is empty"))
        } catch {
            XCTFail("expected MediaExporter.Failure, got \(error)")
        }
    }

    func testStagedCopiesLandUnderOneDirectoryAndPurgeClearsThem() async throws {
        let source = try scratch(Data(repeating: 9, count: 64), named: "IMG_0007.JPG")
        let staged = try MediaExporter.adopt(source)
        XCTAssertEqual(staged.lastPathComponent, "IMG_0007.JPG")
        XCTAssertTrue(staged.path.contains(MediaExporter.directoryName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        // Each staged item gets its own directory, so two copies of the same
        // filename do not collide.
        let second = try MediaExporter.adopt(source)
        XCTAssertNotEqual(staged.path, second.path)

        let exporter = MediaExporter()
        await exporter.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testDiscardRemovesAStagedItemAndItsDirectory() async throws {
        let source = try scratch(Data(repeating: 3, count: 32), named: "clip.mov")
        let staged = try MediaExporter.adopt(source)
        addTeardownBlock { await MediaExporter().purge() }
        let media = ExportedMedia(url: staged, filename: "clip.mov", modified: Date(), byteCount: 32, temporary: true)
        await MediaExporter().discard(media)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    func testPurgePreservesFilesRetainedByDurableQueueCheckpoints() async throws {
        let source = try scratch(Data(repeating: 4, count: 32), named: "kept.jpg")
        let kept = try MediaExporter.adopt(source)
        let orphan = try MediaExporter.adopt(source)
        let exporter = MediaExporter()

        await exporter.purge(excluding: [kept])

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        await exporter.purge()
    }
}
