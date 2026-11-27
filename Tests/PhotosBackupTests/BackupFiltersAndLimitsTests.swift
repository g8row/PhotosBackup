import Foundation
import Photos
import UniformTypeIdentifiers
import XCTest
@testable import PhotosBackup

final class BackupFiltersAndLimitsTests: XCTestCase {
    // MARK: - Media type filter (#32)

    func testMediaFilterMatchesPhotoKitTypes() {
        XCTAssertTrue(BackupMediaFilter.all.matches(.image))
        XCTAssertTrue(BackupMediaFilter.all.matches(.video))
        XCTAssertFalse(BackupMediaFilter.all.matches(.audio))
        XCTAssertFalse(BackupMediaFilter.all.matches(.unknown))

        XCTAssertTrue(BackupMediaFilter.photosOnly.matches(.image))
        XCTAssertFalse(BackupMediaFilter.photosOnly.matches(.video))

        XCTAssertFalse(BackupMediaFilter.videosOnly.matches(.image))
        XCTAssertTrue(BackupMediaFilter.videosOnly.matches(.video))
    }

    func testMediaFilterMatchesUTTypesAndFilenames() {
        XCTAssertTrue(BackupMediaFilter.all.matches(utType: .jpeg))
        XCTAssertTrue(BackupMediaFilter.all.matches(utType: .mpeg4Movie))
        XCTAssertFalse(BackupMediaFilter.all.matches(utType: .plainText))

        XCTAssertTrue(BackupMediaFilter.photosOnly.matches(utType: .heic))
        XCTAssertFalse(BackupMediaFilter.photosOnly.matches(utType: .quickTimeMovie))

        XCTAssertFalse(BackupMediaFilter.videosOnly.matches(utType: .png))
        XCTAssertTrue(BackupMediaFilter.videosOnly.matches(utType: .quickTimeMovie))

        XCTAssertTrue(FolderScanner.isMedia("IMG_0001.HEIC", filter: .photosOnly))
        XCTAssertFalse(FolderScanner.isMedia("clip.mov", filter: .photosOnly))
        XCTAssertFalse(FolderScanner.isMedia("IMG_0001.HEIC", filter: .videosOnly))
        XCTAssertTrue(FolderScanner.isMedia("clip.mov", filter: .videosOnly))
        XCTAssertFalse(FolderScanner.isMedia("notes.txt", filter: .all))
    }

    func testPhotoAlbumStoreFetchOptionsRespectFilterCutoffAndBurstFrames() {
        let allOptions = PhotoAlbumStore.allPhotosOptions()
        XCTAssertTrue(allOptions.includeAllBurstAssets)
        XCTAssertEqual(allOptions.sortDescriptors?.first?.key, "creationDate")
        XCTAssertTrue(allOptions.predicate?.predicateFormat.contains("mediaType == 1") == true)
        XCTAssertTrue(allOptions.predicate?.predicateFormat.contains("mediaType == 2") == true)

        let photosOnly = PhotoAlbumStore.fetchOptions(mediaFilter: .photosOnly)
        XCTAssertTrue(photosOnly.includeAllBurstAssets)
        XCTAssertEqual(photosOnly.predicate?.predicateFormat, "mediaType == 1")

        let videosAfter = PhotoAlbumStore.allPhotosOptions(
            mediaFilter: .videosOnly,
            cutoffDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(videosAfter.includeAllBurstAssets)
        let format = videosAfter.predicate?.predicateFormat ?? ""
        XCTAssertTrue(format.contains("mediaType == 2"), "Unexpected predicate: \(format)")
        XCTAssertTrue(format.contains("creationDate >="), "Unexpected predicate: \(format)")
    }

    // MARK: - Folder scanner filter & cutoff date (#32, #23)

    func testFolderScannerFiltersByMediaTypeAndCutoffDate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-filter-tests-\(UUID().uuidString)", isDirectory: true)
        let picked = root.appendingPathComponent("Import", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldPhoto = picked.appendingPathComponent("old.jpg")
        let newPhoto = picked.appendingPathComponent("new.heic")
        let oldVideo = picked.appendingPathComponent("old.mov")
        let newVideo = picked.appendingPathComponent("new.mp4")
        let note = picked.appendingPathComponent("readme.txt")

        for file in [oldPhoto, newPhoto, oldVideo, newVideo, note] {
            try Data("bytes".utf8).write(to: file)
        }

        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPhoto.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldVideo.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newPhoto.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newVideo.path)

        let store = PickedFolderStore(url: root.appendingPathComponent("folders.json"))

        let photosOnly = try FolderScanner.sources(inPickedFolder: picked, store: store, mediaFilter: .photosOnly)
        XCTAssertEqual(relativePaths(of: photosOnly), ["new.heic", "old.jpg"])

        let videosOnly = try FolderScanner.sources(inPickedFolder: picked, store: store, mediaFilter: .videosOnly)
        XCTAssertEqual(relativePaths(of: videosOnly), ["new.mp4", "old.mov"])

        let afterCutoff = try FolderScanner.sources(inPickedFolder: picked, store: store, mediaFilter: .all, cutoffDate: cutoff)
        XCTAssertEqual(relativePaths(of: afterCutoff), ["new.heic", "new.mp4"])

        let newPhotosOnly = try FolderScanner.sources(inPickedFolder: picked, store: store, mediaFilter: .photosOnly, cutoffDate: cutoff)
        XCTAssertEqual(relativePaths(of: newPhotosOnly), ["new.heic"])
    }

    private func relativePaths(of sources: [MediaSource]) -> [String] {
        sources.compactMap { source in
            if case .folderFile(_, let path) = source { return path }
            return nil
        }
    }

    // MARK: - Daily upload data limit (#14)

    func testDailyUploadBudgetDecisionAndFormatting() {
        XCTAssertEqual(DailyUploadBudget.label(for: 0), "Off")
        XCTAssertFalse(DailyUploadBudget.label(for: 500_000_000).isEmpty)

        XCTAssertEqual(DailyUploadBudget.decision(limitBytes: 0, usedTodayBytes: 10_000_000_000), .allowed)
        XCTAssertEqual(DailyUploadBudget.decision(limitBytes: 1_000_000_000, usedTodayBytes: 999_999_999), .allowed)

        let exact = DailyUploadBudget.decision(limitBytes: 1_000_000_000, usedTodayBytes: 1_000_000_000)
        XCTAssertFalse(exact.allowsUploads)
        XCTAssertTrue(exact.pauseReason?.contains("Daily upload limit reached") == true)

        let over = DailyUploadBudget.decision(limitBytes: 500_000_000, usedTodayBytes: 750_000_000)
        XCTAssertFalse(over.allowsUploads)
        XCTAssertTrue(over.pauseReason?.contains("Resumes tomorrow") == true)
    }

    @MainActor
    func testDailyUploadTrackerPersistsAndResetsOnNewCalendarDay() {
        let suiteName = "DailyUploadTrackerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 0))!
        let day1Later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 23, minute: 59))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 0, minute: 1))!

        let tracker = DailyUploadTracker(defaults: defaults, calendar: calendar, now: day1)
        XCTAssertEqual(tracker.usedTodayBytes, 0)

        tracker.recordUploaded(bytes: 300_000_000, now: day1)
        tracker.recordUploaded(bytes: 250_000_000, now: day1Later)
        tracker.recordUploaded(bytes: -100, now: day1Later)
        XCTAssertEqual(tracker.usedTodayBytes, 550_000_000)

        // Relaunching on the same day restores the counter.
        let reloadedSameDay = DailyUploadTracker(defaults: defaults, calendar: calendar, now: day1Later)
        XCTAssertEqual(reloadedSameDay.usedTodayBytes, 550_000_000)

        // Rolling over to the next day resets to zero.
        reloadedSameDay.refreshDay(now: day2)
        XCTAssertEqual(reloadedSameDay.usedTodayBytes, 0)

        let reloadedNextDay = DailyUploadTracker(defaults: defaults, calendar: calendar, now: day2)
        XCTAssertEqual(reloadedNextDay.usedTodayBytes, 0)
    }

    @MainActor
    func testUploadQueueCountsOnlyUploadedBytesAndPausesOnDailyLimit() async {
        var uploadedTotals: [Int64] = []
        let queue = UploadQueue(worker: { _, source, _, _, emit in
            await emit(.described(name: "item.jpg", byteCount: 400_000_000))
            if case .asset("dup") = source {
                return .alreadyBackedUp(mediaKey: "k-dup")
            }
            return .uploaded(mediaKey: "k-up")
        }, maxConcurrent: 1)

        queue.onBytesUploaded = { bytes in
            uploadedTotals.append(bytes)
            let sum = uploadedTotals.reduce(0, +)
            let decision = DailyUploadBudget.decision(limitBytes: 500_000_000, usedTodayBytes: sum)
            queue.setDailyLimitAccess(allowed: decision.allowsUploads, pauseReason: decision.pauseReason)
        }

        // First: already backed up (400 MB) must NOT count toward the daily limit.
        // Second: uploaded (400 MB) counts -> total 400 MB (< 500 MB), still allowed.
        // Third: uploaded (400 MB) counts -> total 800 MB (>= 500 MB), pauses fourth item!
        queue.enqueue([
            .asset(localIdentifier: "dup"),
            .asset(localIdentifier: "up-1"),
            .asset(localIdentifier: "up-2"),
            .asset(localIdentifier: "up-3"),
        ])

        let deadline = Date().addingTimeInterval(3)
        while queue.dailyLimitPauseReason == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(uploadedTotals, [400_000_000, 400_000_000])
        XCTAssertNotNil(queue.dailyLimitPauseReason)
        XCTAssertEqual(queue.pauseReason, queue.dailyLimitPauseReason)
        XCTAssertEqual(queue.items[0].state, .alreadyBackedUp)
        XCTAssertEqual(queue.items[1].state, .done)
        XCTAssertEqual(queue.items[2].state, .done)
        XCTAssertEqual(queue.items[3].state, .queued)

        // Continued backup policy must stop when paused by daily limit.
        XCTAssertFalse(ContinuedBackupPolicy.shouldContinue(
            hasWorkableItems: true,
            userPaused: false,
            halted: false,
            networkPaused: false,
            systemPaused: false,
            powerPaused: false,
            dailyLimitPaused: true
        ))

        // Lifting the limit resumes the remaining queued item.
        queue.setDailyLimitAccess(allowed: true)
        let resumed = await queue.waitUntilSettled(until: Date().addingTimeInterval(3))
        XCTAssertTrue(resumed)
        XCTAssertEqual(queue.items[3].state, .done)
    }

    // MARK: - Edited photo originals (#33)

    @MainActor
    func testPhotoOriginalFollowUpKeyExclusionAndPersistenceRoundTrip() async throws {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "mk") })
        queue.followUpSources = { source in
            guard case .asset(let identifier) = source else { return [] }
            return [.photoOriginal(localIdentifier: identifier)]
        }

        queue.enqueue([.asset(localIdentifier: "photo-1")])
        let settled = await queue.waitUntilSettled(until: Date().addingTimeInterval(3))
        XCTAssertTrue(settled)
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.items.last?.source, .photoOriginal(localIdentifier: "photo-1"))
        // Photo original is a follow-up, so completedSourceCount still counts only 1 photo.
        XCTAssertEqual(queue.completedSourceCount, 1)
        XCTAssertTrue(queue.completedSourceKeys.contains(UploadQueue.photoOriginalKeyPrefix + "photo-1"))

        let persisted = PersistedUploadItem(
            id: UUID(),
            source: PersistedMediaSource(.photoOriginal(localIdentifier: "photo-1"))!,
            name: "IMG_0001.HEIC (original)",
            byteCount: 2_500_000,
            attempts: 0,
            failureReason: nil,
            failureRetryable: false,
            photoOriginal: true
        )
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedUploadItem.self, from: data)
        XCTAssertEqual(decoded.mediaSource, .photoOriginal(localIdentifier: "photo-1"))
    }

    // MARK: - Preferences persistence & UX copy

    @MainActor
    func testBackupPreferencesPersistsFiltersLimitsAndPhotoOriginals() {
        let suiteName = "BackupPreferencesFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = BackupPreferences(defaults: defaults)
        XCTAssertEqual(initial.mediaFilter, .all)
        XCTAssertFalse(initial.backupFromDateEnabled)
        XCTAssertNil(initial.backupCutoffDate)
        XCTAssertFalse(initial.backUpEditedPhotoOriginals)
        XCTAssertEqual(initial.dailyUploadLimitBytes, 0)

        let cutoff = Date(timeIntervalSince1970: 1_735_689_600)
        initial.mediaFilter = .photosOnly
        initial.backupFromDateEnabled = true
        initial.backupFromDate = cutoff
        initial.backUpEditedPhotoOriginals = true
        initial.dailyUploadLimitBytes = 2_000_000_000

        let reloaded = BackupPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.mediaFilter, .photosOnly)
        XCTAssertTrue(reloaded.backupFromDateEnabled)
        XCTAssertEqual(reloaded.backupCutoffDate?.timeIntervalSince1970 ?? 0, cutoff.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(reloaded.backUpEditedPhotoOriginals)
        XCTAssertEqual(reloaded.dailyUploadLimitBytes, 2_000_000_000)

        XCTAssertTrue(DashboardView.message(for: .started(count: 12)).contains("Checking and backing up"))
    }
}
