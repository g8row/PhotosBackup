import Foundation
import Photos
import UniformTypeIdentifiers

enum BackupConnection: String, CaseIterable, Identifiable {
    case wifiOnly
    case wifiAndCellular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiOnly: return "Wi-Fi Only"
        case .wifiAndCellular: return "Wi-Fi & Cellular"
        }
    }

    var detail: String {
        switch self {
        case .wifiOnly: return "Wait for Wi-Fi before uploading"
        case .wifiAndCellular: return "Back up wherever you are"
        }
    }
}

/// Which media types selected-album and folder scans include (issue #32).
enum BackupMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photosOnly
    case videosOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Photos & Videos"
        case .photosOnly: return "Photos Only"
        case .videosOnly: return "Videos Only"
        }
    }

    func matches(_ mediaType: PHAssetMediaType) -> Bool {
        switch self {
        case .all: return mediaType == .image || mediaType == .video
        case .photosOnly: return mediaType == .image
        case .videosOnly: return mediaType == .video
        }
    }

    func matches(utType: UTType) -> Bool {
        switch self {
        case .all: return utType.conforms(to: .image) || utType.conforms(to: .movie)
        case .photosOnly: return utType.conforms(to: .image)
        case .videosOnly: return utType.conforms(to: .movie)
        }
    }
}

@MainActor
final class BackupPreferences: ObservableObject {
    private enum Key {
        static let selectedAlbumIDs = "backup.selectedAlbumIDs"
        static let automaticBackup = "backup.automatic"
        static let connection = "backup.connection"
        static let completedOnboarding = "app.completedOnboarding"
        static let concurrentUploads = "backup.concurrentUploads"
        static let storageSaver = "backup.storageSaver"
        static let useQuota = "backup.useQuota"
        static let backUpLivePhotoMotion = "backup.livePhotoMotion"
        static let backUpEditedPhotoOriginals = "backup.editedPhotoOriginals"
        static let keepAliveEnabled = "backup.keepAlive.enabled"
        static let keepAliveMode = "backup.keepAlive.mode"
        static let albumsFromLibrary = "backup.albumsFromLibrary"
        static let onlyWhileCharging = "backup.onlyWhileCharging"
        static let minimumBatteryPercent = "backup.minimumBatteryPercent"
        static let significantLocationWake = "backup.significantLocationWake"
        static let mediaFilter = "backup.mediaFilter"
        static let backupFromDateEnabled = "backup.fromDateEnabled"
        static let backupFromDate = "backup.fromDate"
        static let dailyUploadLimitBytes = "backup.dailyUploadLimitBytes"
    }

    @Published var selectedAlbumIDs: Set<String> { didSet { saveAlbumIDs() } }
    @Published var automaticBackup: Bool { didSet { defaults.set(automaticBackup, forKey: Key.automaticBackup) } }
    @Published var connection: BackupConnection { didSet { defaults.set(connection.rawValue, forKey: Key.connection) } }
    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published var concurrentUploads: Int { didSet { defaults.set(concurrentUploads, forKey: Key.concurrentUploads) } }
    @Published var storageSaver: Bool { didSet { defaults.set(storageSaver, forKey: Key.storageSaver) } }
    @Published var useQuota: Bool { didSet { defaults.set(useQuota, forKey: Key.useQuota) } }
    @Published var backUpLivePhotoMotion: Bool { didSet { defaults.set(backUpLivePhotoMotion, forKey: Key.backUpLivePhotoMotion) } }
    /// Opt-in upload of the unedited `.photo` resource alongside the rendered
    /// edit for edited photos (issue #33).
    @Published var backUpEditedPhotoOriginals: Bool { didSet { defaults.set(backUpEditedPhotoOriginals, forKey: Key.backUpEditedPhotoOriginals) } }
    /// Keep the app running in the background while work is queued. See
    /// `BackgroundKeepAlive`.
    @Published var keepAliveEnabled: Bool { didSet { defaults.set(keepAliveEnabled, forKey: Key.keepAliveEnabled) } }
    @Published var keepAliveMode: KeepAliveMode { didSet { defaults.set(keepAliveMode.rawValue, forKey: Key.keepAliveMode) } }
    @Published var albumsFromLibrary: Bool { didSet { defaults.set(albumsFromLibrary, forKey: Key.albumsFromLibrary) } }
    /// Require external power for automatic/background backups and set
    /// `requiresExternalPower` on background processing requests (issue #14).
    @Published var onlyWhileCharging: Bool { didSet { defaults.set(onlyWhileCharging, forKey: Key.onlyWhileCharging) } }
    /// Pause automatic/background backups while unplugged below this percentage.
    /// `0` disables the threshold.
    @Published var minimumBatteryPercent: Int { didSet { defaults.set(minimumBatteryPercent, forKey: Key.minimumBatteryPercent) } }
    /// Opt-in significant-location-change wake (arrival home / travel) for
    /// unattended photo discovery; requires Always location permission.
    @Published var significantLocationWake: Bool { didSet { defaults.set(significantLocationWake, forKey: Key.significantLocationWake) } }
    /// Restrict selected-album and folder backups to photos, videos, or both (issue #32).
    @Published var mediaFilter: BackupMediaFilter { didSet { defaults.set(mediaFilter.rawValue, forKey: Key.mediaFilter) } }
    /// When on, only items created on or after `backupFromDate` are included in scans (issue #23).
    @Published var backupFromDateEnabled: Bool { didSet { defaults.set(backupFromDateEnabled, forKey: Key.backupFromDateEnabled) } }
    @Published var backupFromDate: Date { didSet { defaults.set(backupFromDate.timeIntervalSince1970, forKey: Key.backupFromDate) } }
    /// Maximum bytes to upload per local calendar day (`0` = unlimited, issue #14).
    @Published var dailyUploadLimitBytes: Int64 { didSet { defaults.set(max(0, dailyUploadLimitBytes), forKey: Key.dailyUploadLimitBytes) } }

    /// Active cutoff date when `backupFromDateEnabled` is on, or `nil`.
    var backupCutoffDate: Date? { backupFromDateEnabled ? backupFromDate : nil }

    /// True when either the media type filter or the cutoff date narrows the library.
    var hasActiveScanFilter: Bool { mediaFilter != .all || backupFromDateEnabled }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedAlbumIDs = Set(defaults.stringArray(forKey: Key.selectedAlbumIDs) ?? [])
        automaticBackup = defaults.object(forKey: Key.automaticBackup) as? Bool ?? true
        connection = BackupConnection(rawValue: defaults.string(forKey: Key.connection) ?? "") ?? .wifiOnly
        completedOnboarding = defaults.bool(forKey: Key.completedOnboarding)
        // `object(forKey:)` rather than `integer(forKey:)`: an unset key reads
        // as 0, which is not a legal concurrency and would clamp to 1.
        concurrentUploads = UploadQueue.clampedConcurrency(
            defaults.object(forKey: Key.concurrentUploads) as? Int ?? 2)
        storageSaver = defaults.bool(forKey: Key.storageSaver)
        useQuota = defaults.bool(forKey: Key.useQuota)
        // On unless turned off: Free up space only offers a Live Photo with its
        // motion attached. An update uploads the motion of every Live Photo
        // already backed up, a few MB each.
        backUpLivePhotoMotion = defaults.object(forKey: Key.backUpLivePhotoMotion) as? Bool ?? true
        // Off until asked for: uploading an extra copy of every edited photo
        // adds visible duplicates in Google Photos for users who don't want them.
        backUpEditedPhotoOriginals = defaults.bool(forKey: Key.backUpEditedPhotoOriginals)
        // On unless turned off: without it iOS suspends the app seconds after
        // it leaves the foreground, which is the most reported problem. Silent
        // audio needs no permission, and it stops once the queue cannot move.
        keepAliveEnabled = defaults.object(forKey: Key.keepAliveEnabled) as? Bool ?? true
        keepAliveMode = KeepAliveMode(rawValue: defaults.string(forKey: Key.keepAliveMode) ?? "") ?? .audio
        // Off until asked for: it creates albums in the user's Google account,
        // which an update should not start doing on its own.
        albumsFromLibrary = defaults.bool(forKey: Key.albumsFromLibrary)
        onlyWhileCharging = defaults.bool(forKey: Key.onlyWhileCharging)
        minimumBatteryPercent = max(0, min(100, defaults.integer(forKey: Key.minimumBatteryPercent)))
        significantLocationWake = defaults.bool(forKey: Key.significantLocationWake)
        mediaFilter = BackupMediaFilter(rawValue: defaults.string(forKey: Key.mediaFilter) ?? "") ?? .all
        backupFromDateEnabled = defaults.bool(forKey: Key.backupFromDateEnabled)
        if let savedTimestamp = defaults.object(forKey: Key.backupFromDate) as? Double {
            backupFromDate = Date(timeIntervalSince1970: savedTimestamp)
        } else {
            backupFromDate = Date()
        }
        if let stored = defaults.object(forKey: Key.dailyUploadLimitBytes) as? NSNumber {
            dailyUploadLimitBytes = max(0, stored.int64Value)
        } else {
            dailyUploadLimitBytes = 0
        }
    }

    func toggle(albumID: String) {
        if selectedAlbumIDs.contains(albumID) { selectedAlbumIDs.remove(albumID) }
        else { selectedAlbumIDs.insert(albumID) }
    }

    func resetOnboarding() { completedOnboarding = false }

    private func saveAlbumIDs() {
        defaults.set(Array(selectedAlbumIDs).sorted(), forKey: Key.selectedAlbumIDs)
    }
}

struct PhotoAlbum: Identifiable, Equatable {
    /// Stable id for the synthetic album that backs up the entire library.
    static let allPhotosID = "photosbackup.all-photos"

    let id: String
    let title: String
    let count: Int
    let symbol: String
    /// `nil` for the synthetic "All Photos" album, which spans the whole
    /// library rather than a single collection.
    let collection: PHAssetCollection?

    var isAllPhotos: Bool { id == Self.allPhotosID }

    static func == (lhs: PhotoAlbum, rhs: PhotoAlbum) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.count == rhs.count
    }
}

@MainActor
final class PhotoAlbumStore: ObservableObject {
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var isLoading = false
    /// Backed-up item counts per album id, filled in lazily off the main actor.
    @Published private(set) var backedUpCounts: [String: Int] = [:]
    /// Total matching item counts per selected album id under the active
    /// media filter and cutoff date, paired with `backedUpCounts`.
    @Published private(set) var eligibleCounts: [String: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?
    private var lastCountsRefreshStartedAt = Date.distantPast
    /// Shortest gap between two backed-up recounts. One recount enumerates every
    /// asset in every selected album — the whole library when "All Photos" is
    /// selected — and the trigger is the completion ledger, which moves once per
    /// uploaded photo. Without a floor a long backup keeps a full-library
    /// PhotoKit scan running end to end, competing with the uploads themselves.
    private static let countsRefreshInterval: TimeInterval = 2

    var canRead: Bool { authorization == .authorized || authorization == .limited }
    /// True when the user granted access to a hand-picked subset. Every fetch is
    /// then scoped to that subset, so counts are not library-wide.
    var isLimited: Bool { authorization == .limited }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead { await refresh() }
    }

    /// Enumerating collections and counting their assets is slow enough on a
    /// large library to drop frames, so it runs off the main actor and only the
    /// finished list is published. Concurrent callers share one pass.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else { albums = []; backedUpCounts = [:]; return }
        isLoading = true
        let task = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.loadAlbums() }.value
            guard let self else { return }
            self.albums = loaded
            self.isLoading = false
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Fire-and-forget variant for `onAppear`, which cannot await.
    func refreshInBackground() {
        guard refreshTask == nil else { return }
        Task { await refresh() }
    }

    private nonisolated static func loadAlbums() -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []
        var seen = Set<String>()
        func append(_ collection: PHAssetCollection) {
            guard seen.insert(collection.localIdentifier).inserted else { return }
            let fetch = PHAsset.fetchAssets(in: collection, options: .includingBurstFrames)
            guard fetch.count > 0 else { return }
            result.append(PhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                count: fetch.count,
                symbol: symbol(for: collection),
                collection: collection
            ))
        }

        let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { collection, _, _ in append(collection) }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { collection, _, _ in append(collection) }

        var ordered = result.sorted { lhs, rhs in
            if lhs.symbol == "camera.fill" { return true }
            if rhs.symbol == "camera.fill" { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        // A synthetic album for the entire library, always pinned to the top.
        let allCount = PHAsset.fetchAssets(with: allPhotosOptions()).count
        if allCount > 0 {
            ordered.insert(PhotoAlbum(
                id: PhotoAlbum.allPhotosID,
                title: "All Photos",
                count: allCount,
                symbol: "photo.on.rectangle.angled",
                collection: nil
            ), at: 0)
        }
        return ordered
    }

    /// Asset identifiers per album matching `mediaFilter` and `cutoffDate`,
    /// enumerated off the main actor.
    func assetIdentifiers(
        for albumIDs: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) async -> [String: [String]] {
        let targets = albums.filter { albumIDs.contains($0.id) }
            .map { ($0.id, $0.collection) }
        guard !targets.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var result: [String: [String]] = [:]
            for (id, collection) in targets {
                let assets = collection.map {
                    PHAsset.fetchAssets(in: $0, options: Self.fetchOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate))
                } ?? PHAsset.fetchAssets(with: Self.allPhotosOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate))
                var identifiers: [String] = []
                identifiers.reserveCapacity(assets.count)
                assets.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
                result[id] = identifiers
            }
            return result
        }.value
    }

    func sources(
        for albumIDs: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) async -> [MediaSource] {
        // Albums overlap (and "All Photos" contains all of them), so dedup by
        // asset identifier — otherwise one asset becomes several queue sources.
        let byAlbum = await assetIdentifiers(for: albumIDs, mediaFilter: mediaFilter, cutoffDate: cutoffDate)
        var seen = Set<String>()
        var sources: [MediaSource] = []
        for album in albums where albumIDs.contains(album.id) {
            for identifier in byAlbum[album.id] ?? [] where seen.insert(identifier).inserted {
                sources.append(.asset(localIdentifier: identifier))
            }
        }
        return sources
    }

    /// Snapshot of selected albums suitable for off-main-actor PhotoKit scans.
    func scanTargets(for albumIDs: Set<String>) -> [(id: String, collection: PHAssetCollection?)] {
        albums.filter { albumIDs.contains($0.id) }.map { ($0.id, $0.collection) }
    }

    /// Enumerate every selected album off the main actor, filtered by media type
    /// and optional creation-date cutoff.
    nonisolated static func sources(
        for targets: [(id: String, collection: PHAssetCollection?)],
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> [MediaSource] {
        var seen = Set<String>()
        var sources: [MediaSource] = []
        for (_, collection) in targets {
            let assets: PHFetchResult<PHAsset>
            if let collection {
                assets = PHAsset.fetchAssets(in: collection, options: fetchOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate))
            } else {
                assets = PHAsset.fetchAssets(with: allPhotosOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate))
            }
            assets.enumerateObjects { asset, _, _ in
                guard seen.insert(asset.localIdentifier).inserted else { return }
                sources.append(.asset(localIdentifier: asset.localIdentifier))
            }
        }
        return sources
    }

    /// Restrict a PhotoKit persistent-change batch to the selected albums off
    /// the main actor, applying the active media type filter and cutoff date.
    nonisolated static func sources(
        for targets: [(id: String, collection: PHAssetCollection?)],
        selectedAlbumIDs: Set<String>,
        matching identifiers: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> [MediaSource] {
        guard !identifiers.isEmpty else { return [] }
        if selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(identifiers),
                options: fetchOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate)
            )
            var result: [MediaSource] = []
            assets.enumerateObjects { asset, _, _ in
                guard matchesFilter(asset, mediaFilter: mediaFilter, cutoffDate: cutoffDate) else { return }
                result.append(.asset(localIdentifier: asset.localIdentifier))
            }
            return result
        }

        var matched = Set<String>()
        let options = fetchOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate)
        for (_, collection) in targets {
            guard let collection else { continue }
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            assets.enumerateObjects { asset, _, stop in
                if identifiers.contains(asset.localIdentifier) { matched.insert(asset.localIdentifier) }
                if matched.count == identifiers.count { stop.pointee = true }
            }
        }
        return matched.map { .asset(localIdentifier: $0) }
    }

    /// Synchronous variant, retained for callers already on a background thread.
    func sourcesSynchronously(
        for albumIDs: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> [MediaSource] {
        Self.sources(for: scanTargets(for: albumIDs), mediaFilter: mediaFilter, cutoffDate: cutoffDate)
    }

    /// Recompute "N of M backed up" for the selected albums under the active
    /// filter settings. `isBackedUp` is resolved against the queue's durable
    /// completion ledger.
    func refreshBackedUpCounts(
        for albumIDs: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil,
        isBackedUp: @escaping @Sendable (String) -> Bool
    ) {
        countsTask?.cancel()
        guard canRead, !albumIDs.isEmpty else { backedUpCounts = [:]; eligibleCounts = [:]; return }
        countsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Leading edge, then at most one pass per interval: the first call
            // (a tab appearing, a selection change) is not delayed, and a burst
            // of upload completions collapses into a single recount.
            let sinceLast = Date().timeIntervalSince(self.lastCountsRefreshStartedAt)
            if sinceLast < Self.countsRefreshInterval {
                try? await Task.sleep(nanoseconds: UInt64((Self.countsRefreshInterval - sinceLast) * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            self.lastCountsRefreshStartedAt = Date()
            let byAlbum = await self.assetIdentifiers(for: albumIDs, mediaFilter: mediaFilter, cutoffDate: cutoffDate)
            guard !Task.isCancelled else { return }
            let (counts, totals) = await Task.detached(priority: .utility) {
                let backedUp = byAlbum.mapValues { identifiers in
                    identifiers.reduce(into: 0) { total, id in
                        if isBackedUp(id) { total += 1 }
                    }
                }
                let eligible = byAlbum.mapValues(\.count)
                return (backedUp, eligible)
            }.value
            guard !Task.isCancelled else { return }
            self.backedUpCounts = counts
            self.eligibleCounts = totals
        }
    }

    /// Restrict a PhotoKit persistent-change batch to the selected albums.
    /// The changed identifier set is normally tiny, while the full-scan method
    /// above remains the iOS 15 and expired-token fallback.
    func sources(
        for albumIDs: Set<String>,
        matching identifiers: Set<String>,
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> [MediaSource] {
        Self.sources(
            for: scanTargets(for: albumIDs),
            selectedAlbumIDs: albumIDs,
            matching: identifiers,
            mediaFilter: mediaFilter,
            cutoffDate: cutoffDate
        )
    }

    nonisolated static func matchesFilter(
        _ asset: PHAsset,
        mediaFilter: BackupMediaFilter,
        cutoffDate: Date?
    ) -> Bool {
        guard mediaFilter.matches(asset.mediaType) else { return false }
        if let cutoffDate {
            guard let created = asset.creationDate, created >= cutoffDate else { return false }
        }
        return true
    }

    nonisolated static func assetPredicate(
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> NSPredicate {
        let mediaPredicate: NSPredicate
        switch mediaFilter {
        case .all:
            mediaPredicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        case .photosOnly:
            mediaPredicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
        case .videosOnly:
            mediaPredicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.video.rawValue
            )
        }
        guard let cutoffDate else { return mediaPredicate }
        let datePredicate = NSPredicate(format: "creationDate >= %@", cutoffDate as NSDate)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [mediaPredicate, datePredicate])
    }

    nonisolated static func fetchOptions(
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = assetPredicate(mediaFilter: mediaFilter, cutoffDate: cutoffDate)
        options.includeAllBurstAssets = true
        return options
    }

    /// Images and videos across the whole library, newest first, for the
    /// synthetic "All Photos" album.
    nonisolated static func allPhotosOptions(
        mediaFilter: BackupMediaFilter = .all,
        cutoffDate: Date? = nil
    ) -> PHFetchOptions {
        let options = fetchOptions(mediaFilter: mediaFilter, cutoffDate: cutoffDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    nonisolated static func symbol(for collection: PHAssetCollection) -> String {
        switch collection.assetCollectionSubtype {
        case .smartAlbumUserLibrary: return "camera.fill"
        case .smartAlbumScreenshots: return "iphone"
        case .smartAlbumSelfPortraits: return "person.crop.square"
        case .smartAlbumFavorites: return "heart.fill"
        case .smartAlbumVideos: return "video.fill"
        case .smartAlbumLivePhotos: return "livephoto"
        case .smartAlbumRecentlyAdded: return "clock.fill"
        default: return "rectangle.stack.fill"
        }
    }
}
