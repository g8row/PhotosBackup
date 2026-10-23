import Foundation
import Photos

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
        static let albumsFromLibrary = "backup.albumsFromLibrary"
    }

    @Published var selectedAlbumIDs: Set<String> { didSet { saveAlbumIDs() } }
    @Published var automaticBackup: Bool { didSet { defaults.set(automaticBackup, forKey: Key.automaticBackup) } }
    @Published var connection: BackupConnection { didSet { defaults.set(connection.rawValue, forKey: Key.connection) } }
    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published var concurrentUploads: Int { didSet { defaults.set(concurrentUploads, forKey: Key.concurrentUploads) } }
    @Published var storageSaver: Bool { didSet { defaults.set(storageSaver, forKey: Key.storageSaver) } }
    @Published var useQuota: Bool { didSet { defaults.set(useQuota, forKey: Key.useQuota) } }
    @Published var backUpLivePhotoMotion: Bool { didSet { defaults.set(backUpLivePhotoMotion, forKey: Key.backUpLivePhotoMotion) } }
    @Published var albumsFromLibrary: Bool { didSet { defaults.set(albumsFromLibrary, forKey: Key.albumsFromLibrary) } }

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
        // Off until asked for: turning it on uploads the motion of every Live
        // Photo already backed up, a few MB each, which an update should not
        // start on its own.
        backUpLivePhotoMotion = defaults.bool(forKey: Key.backUpLivePhotoMotion)
        // Off until asked for, like motion: it creates albums in the user's
        // Google account, which an update should not start doing on its own.
        albumsFromLibrary = defaults.bool(forKey: Key.albumsFromLibrary)
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
            let fetch = PHAsset.fetchAssets(in: collection, options: nil)
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

    /// Asset identifiers per album, enumerated off the main actor.
    func assetIdentifiers(for albumIDs: Set<String>) async -> [String: [String]] {
        let targets = albums.filter { albumIDs.contains($0.id) }
            .map { ($0.id, $0.collection) }
        guard !targets.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var result: [String: [String]] = [:]
            for (id, collection) in targets {
                let assets = collection.map { PHAsset.fetchAssets(in: $0, options: nil) }
                    ?? PHAsset.fetchAssets(with: Self.allPhotosOptions())
                var identifiers: [String] = []
                identifiers.reserveCapacity(assets.count)
                assets.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
                result[id] = identifiers
            }
            return result
        }.value
    }

    func sources(for albumIDs: Set<String>) async -> [MediaSource] {
        // Albums overlap (and "All Photos" contains all of them), so dedup by
        // asset identifier — otherwise one asset becomes several queue sources.
        let byAlbum = await assetIdentifiers(for: albumIDs)
        var seen = Set<String>()
        var sources: [MediaSource] = []
        for album in albums where albumIDs.contains(album.id) {
            for identifier in byAlbum[album.id] ?? [] where seen.insert(identifier).inserted {
                sources.append(.asset(localIdentifier: identifier))
            }
        }
        return sources
    }

    /// Synchronous variant, retained for the background-window scan where the
    /// work already runs outside a frame deadline.
    func sourcesSynchronously(for albumIDs: Set<String>) -> [MediaSource] {
        var seen = Set<String>()
        var sources: [MediaSource] = []
        for album in albums where albumIDs.contains(album.id) {
            let assets: PHFetchResult<PHAsset>
            if let collection = album.collection {
                assets = PHAsset.fetchAssets(in: collection, options: nil)
            } else {
                assets = PHAsset.fetchAssets(with: Self.allPhotosOptions())
            }
            assets.enumerateObjects { asset, _, _ in
                guard seen.insert(asset.localIdentifier).inserted else { return }
                sources.append(.asset(localIdentifier: asset.localIdentifier))
            }
        }
        return sources
    }

    /// Recompute "N of M backed up" for the selected albums. `isBackedUp` is
    /// resolved against the queue's durable completion ledger.
    func refreshBackedUpCounts(for albumIDs: Set<String>,
                               isBackedUp: @escaping @Sendable (String) -> Bool) {
        countsTask?.cancel()
        guard canRead, !albumIDs.isEmpty else { backedUpCounts = [:]; return }
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
            let byAlbum = await self.assetIdentifiers(for: albumIDs)
            guard !Task.isCancelled else { return }
            let counts = await Task.detached(priority: .utility) {
                byAlbum.mapValues { identifiers in
                    identifiers.reduce(into: 0) { total, id in
                        if isBackedUp(id) { total += 1 }
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            self.backedUpCounts = counts
        }
    }

    /// Restrict a PhotoKit persistent-change batch to the selected albums.
    /// The changed identifier set is normally tiny, while the full-scan method
    /// above remains the iOS 15 and expired-token fallback.
    func sources(for albumIDs: Set<String>, matching identifiers: Set<String>) -> [MediaSource] {
        guard !identifiers.isEmpty else { return [] }
        if albumIDs.contains(PhotoAlbum.allPhotosID) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var result: [MediaSource] = []
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                result.append(.asset(localIdentifier: asset.localIdentifier))
            }
            return result
        }

        var matched = Set<String>()
        for album in albums where albumIDs.contains(album.id) {
            guard let collection = album.collection else { continue }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, stop in
                if identifiers.contains(asset.localIdentifier) { matched.insert(asset.localIdentifier) }
                if matched.count == identifiers.count { stop.pointee = true }
            }
        }
        return matched.map { .asset(localIdentifier: $0) }
    }

    /// Images and videos across the whole library, newest first, for the
    /// synthetic "All Photos" album.
    nonisolated static func allPhotosOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
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
