import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where one queued item came from. Everything reaches `GPMCClient.upload` as a
/// plain file on disk, so this is only ever a recipe for producing that file.
enum MediaSource: Equatable, Sendable {
    /// A `PHAsset` local identifier. Preferred: it carries the original
    /// filename and capture date, which a picker copy loses.
    case asset(localIdentifier: String)
    /// A picker selection we could not resolve to an asset (no library
    /// permission, or a cloud-only item chosen through the limited picker).
    /// Carries the item provider so the file is copied lazily at export time.
    case picked(PickedItem)
    /// An existing file. Used by tests and by anything that already staged one.
    case file(URL)
    /// The motion of the Live Photo with this `PHAsset` identifier: its paired
    /// video, attached to the still already backed up so the item plays as a
    /// Live Photo and the Google Photos app's Free up space can offer it.
    case livePhotoMotion(localIdentifier: String)
    /// The version of the photo with this `PHAsset` identifier that the Google
    /// Photos app's own edit was applied on (`.adjustmentBasePhoto`): the
    /// camera's Portrait blur or crop, before Google's edit. The Google Photos
    /// app counts a photo it edited as backed up only once the account holds
    /// this version (seen on device on 2026-09-19); the finished edit and the
    /// original do not count.
    case editBase(localIdentifier: String)
}

/// A picked item with no resolvable asset id. Wraps the provider so the file
/// can be copied lazily at export time. Reference identity is enough for the
/// queue's dedup, and picked items are never persisted.
final class PickedItem: @unchecked Sendable, Equatable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
    static func == (lhs: PickedItem, rhs: PickedItem) -> Bool { lhs === rhs }
}

struct ExportedMedia: Equatable, Sendable {
    let url: URL
    let filename: String
    let modified: Date
    let byteCount: Int64
    /// False for `.file` sources, which the exporter does not own and must not delete.
    let temporary: Bool
    /// For a Live Photo motion: SHA-1 of the still the motion belongs to, the
    /// dedup key of the item it is attached to.
    var pairedStillHash: Data? = nil
    /// For a library asset on iOS 18 and later: its `adjustmentTimestamp` as
    /// read before the file was copied. Nil when it was never edited.
    var adjustedAt: Date? = nil
}

/// Turns a `MediaSource` into a file `GPMCClient.upload` can read, and cleans
/// up after itself. Owned files live in protected, backup-excluded Application
/// Support so iOS cannot evict a body that its background session still needs.
actor MediaExporter {
    enum Failure: LocalizedError, Equatable {
        case missingAsset
        case noResource
        case unreadable(String)
        case liveOnly
        case noMotion
        case noEditBase
        case iCloudDownloadRequired
        var errorDescription: String? {
            switch self {
            case .missingAsset: return "That item is no longer in your photo library."
            case .noResource: return "That item has no file to upload."
            case .liveOnly: return "That item is a Live Photo motion track, which this release does not upload."
            case .noMotion: return "That Live Photo has no motion to back up."
            case .noEditBase: return "That photo has no Google Photos edit to back up the base of."
            case .iCloudDownloadRequired: return "That item is only in iCloud. It will continue when the app is open."
            case .unreadable(let detail): return "Could not read that item: \(detail)"
            }
        }
    }

    static let directoryName = "gpmc-uploads"

    static var root: URL {
        // Background URLSession upload bodies must not live in Caches: iOS may
        // evict that directory while a multi-hour task still owns the file.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Moves a system-owned temp file into our staging directory. Static so the
    /// `Transferable` closure, which runs wherever the system pleases, can use it.
    static func adopt(_ file: URL) throws -> URL {
        let destination = try stage(named: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Copy a picked item provider's file into staging. `loadFileRepresentation`
    /// hands back a URL valid only inside its closure, so the copy happens there.
    static func copyToStaging(from provider: NSItemProvider) async throws -> URL {
        let movie = UTType.movie.identifier
        let image = UTType.image.identifier
        let typeID: String
        if provider.hasItemConformingToTypeIdentifier(movie) { typeID = movie }
        else if provider.hasItemConformingToTypeIdentifier(image) { typeID = image }
        else { throw Failure.noResource }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                if let url {
                    do { continuation.resume(returning: try adopt(url)) }
                    catch { continuation.resume(throwing: error) }
                } else {
                    continuation.resume(throwing: error ?? Failure.noResource)
                }
            }
        }
    }

    static func stage(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        try? (directory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        let safe = name.isEmpty ? "item" : name
        return directory.appendingPathComponent(safe)
    }

    /// Remove only orphaned staging directories. Files named by restored queue
    /// checkpoints may still be feeding an iOS-owned background upload.
    func purge(excluding retainedFiles: Set<URL> = []) {
        let retainedDirectories = Set(retainedFiles.map { $0.standardizedFileURL.deletingLastPathComponent() })
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where !retainedDirectories.contains(child.standardizedFileURL) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    func export(_ source: MediaSource, allowsNetworkAccess: Bool = true) async throws -> ExportedMedia {
        switch source {
        case .file(let url):
            return try describe(url, filename: url.lastPathComponent, modified: nil, temporary: false)
        case .asset(let identifier):
            return try await exportAsset(identifier, allowsNetworkAccess: allowsNetworkAccess)
        case .picked(let picked):
            let url = try await Self.copyToStaging(from: picked.provider)
            return try describe(url, filename: url.lastPathComponent, modified: nil, temporary: true)
        case .livePhotoMotion(let identifier):
            return try await exportMotion(identifier, allowsNetworkAccess: allowsNetworkAccess)
        case .editBase(let identifier):
            return try await exportEditBase(identifier, allowsNetworkAccess: allowsNetworkAccess)
        }
    }

    /// Remove a staged file once the queue is finished with it.
    func discard(_ media: ExportedMedia) {
        guard media.temporary else { return }
        try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
    }

    /// The resource to upload, in order of preference: the one the Google Photos
    /// app would upload itself. That is the rendered edit for an edited asset and
    /// the original otherwise, and its Free up space only counts a photo on this
    /// iPhone as backed up when the account holds those exact bytes — an edited
    /// photo backed up as its original never qualifies. This includes the many
    /// Live Photos the camera saves with an adjustment already applied.
    ///
    /// The list follows the asset's media type. An edited video keeps a
    /// rendered still (`.fullSizePhoto`) beside its rendered video; a single
    /// edited-first list uploaded that still in place of the video, so the
    /// Google Photos app never counted the video as backed up (seen on device
    /// on 2026-09-19).
    ///
    /// `.pairedVideo` / `.fullSizePairedVideo` are the Live Photo motion track.
    /// Live Photos are a follow-up (ADR-001), so only the still or the plain
    /// video is uploaded here.
    static func uploadResourceTypes(for mediaType: PHAssetMediaType, edited: Bool) -> [PHAssetResourceType] {
        let photo: [PHAssetResourceType] = edited ? [.fullSizePhoto, .photo] : [.photo, .fullSizePhoto]
        let video: [PHAssetResourceType] = edited ? [.fullSizeVideo, .video] : [.video, .fullSizeVideo]
        switch mediaType {
        case .image: return photo
        case .video: return video
        default: return photo + video
        }
    }

    /// The paired video attached as a Live Photo's motion: the rendered edit's
    /// video for an edited asset, as the Google Photos app attaches it.
    static func motionResourceTypes(edited: Bool) -> [PHAssetResourceType] {
        edited ? [.fullSizePairedVideo, .pairedVideo] : [.pairedVideo]
    }

    /// A rendered edit is named `FullSizeRender.heic`. Upload it under the
    /// original's name instead, with the rendition's file type.
    static func uploadFilename(original: String?, rendition: String) -> String {
        guard let original, !original.isEmpty else { return rendition }
        let originalType = (original as NSString).pathExtension
        let renditionType = (rendition as NSString).pathExtension
        guard !renditionType.isEmpty, renditionType.lowercased() != originalType.lowercased() else { return original }
        let type = originalType == originalType.uppercased() ? renditionType.uppercased() : renditionType.lowercased()
        return (original as NSString).deletingPathExtension + "." + type
    }

    private func exportAsset(_ identifier: String, allowsNetworkAccess: Bool) async throws -> ExportedMedia {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.missingAsset
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred = Self.uploadResourceTypes(for: asset.mediaType, edited: asset.hasAdjustments)
        guard let resource = preferred.compactMap({ type in resources.first { $0.type == type } }).first else {
            throw resources.isEmpty ? Failure.noResource : Failure.liveOnly
        }
        let original = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename
        let filename = Self.uploadFilename(original: original, rendition: resource.originalFilename)
        // Read before the copy: an edit landing mid-copy then leaves the older
        // timestamp on record, so the next scan re-checks the asset.
        var adjustedAt: Date?
        if #available(iOS 18, *) { adjustedAt = asset.adjustmentTimestamp }
        var media = try await stage(resource, as: filename, of: asset, allowsNetworkAccess: allowsNetworkAccess)
        media.adjustedAt = adjustedAt
        return media
    }

    /// The format the Google Photos app records its own edits in.
    static let googlePhotosEditFormat = "com.google.photos.editing.filtering.nondestructive"

    /// Whether a photo carries a version an edit was stacked on. Reads only the
    /// resource list; the export confirms the edit is the Google Photos app's.
    /// Photos edited only by the camera or in Apple Photos have none.
    static func hasEditBase(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image && asset.hasAdjustments
            && PHAssetResource.assetResources(for: asset).contains { $0.type == .adjustmentBasePhoto }
    }

    /// The version a Google Photos edit was applied on, staged under the
    /// original's name. Any other stacked edit settles without an upload: the
    /// Google Photos app is only known to check this version for its own.
    private func exportEditBase(_ identifier: String, allowsNetworkAccess: Bool) async throws -> ExportedMedia {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.missingAsset
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let base = resources.first(where: { $0.type == .adjustmentBasePhoto }),
              let adjustment = resources.first(where: { $0.type == .adjustmentData }),
              await Self.adjustmentFormat(of: adjustment) == Self.googlePhotosEditFormat else {
            throw Failure.noEditBase
        }
        let original = resources.first { $0.type == .photo }?.originalFilename
        let filename = Self.uploadFilename(original: original, rendition: base.originalFilename)
        return try await stage(base, as: filename, of: asset, allowsNetworkAccess: allowsNetworkAccess)
    }

    /// `adjustmentFormatIdentifier` from an asset's adjustment plist, or nil.
    private static func adjustmentFormat(of resource: PHAssetResource) async -> String? {
        let collector = DataCollector()
        let finished: Bool = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: nil) { chunk in
                collector.append(chunk)
            } completionHandler: { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard finished,
              let plist = try? PropertyListSerialization.propertyList(from: collector.data, format: nil) as? [String: Any]
        else { return nil }
        return plist["adjustmentFormatIdentifier"] as? String
    }

    /// A Live Photo's paired video, plus the hash of the still it belongs to.
    /// The still is hashed as it streams in rather than staged: only its hash
    /// is needed, to name the item the motion is attached to.
    private func exportMotion(_ identifier: String, allowsNetworkAccess: Bool) async throws -> ExportedMedia {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.missingAsset
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let edited = asset.hasAdjustments
        func first(_ types: [PHAssetResourceType]) -> PHAssetResource? {
            types.compactMap { type in resources.first { $0.type == type } }.first
        }
        guard let video = first(Self.motionResourceTypes(edited: edited)) else { throw Failure.noMotion }
        guard let still = first(Self.uploadResourceTypes(for: .image, edited: edited)) else { throw Failure.noResource }
        let stillHash = try await Self.sha1(of: still, allowsNetworkAccess: allowsNetworkAccess)
        let original = resources.first { $0.type == .pairedVideo }?.originalFilename
        let filename = Self.uploadFilename(original: original, rendition: video.originalFilename)
        var media = try await stage(video, as: filename, of: asset, allowsNetworkAccess: allowsNetworkAccess)
        media.pairedStillHash = stillHash
        return media
    }

    private func stage(_ resource: PHAssetResource, as filename: String, of asset: PHAsset,
                       allowsNetworkAccess: Bool) async throws -> ExportedMedia {
        let destination = try Self.stage(named: filename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw Self.readFailure(error, allowsNetworkAccess: allowsNetworkAccess)
        }
        do {
            return try describe(destination, filename: filename,
                                modified: asset.creationDate ?? asset.modificationDate, temporary: true)
        } catch {
            // `describe` rejects an empty file. The write itself succeeded, so
            // the earlier cleanup did not run and the directory would linger
            // until the next launch's purge.
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    private static func sha1(of resource: PHAssetResource, allowsNetworkAccess: Bool) async throws -> Data {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        let hasher = StreamingSHA1()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    hasher.update(data)
                } completionHandler: { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            throw readFailure(error, allowsNetworkAccess: allowsNetworkAccess)
        }
        try Task.checkCancellation()
        return hasher.finalize()
    }

    private static func readFailure(_ error: Error, allowsNetworkAccess: Bool) -> Error {
        if Task.isCancelled { return CancellationError() }
        let nsError = error as NSError
        if !allowsNetworkAccess, nsError.domain == PHPhotosErrorDomain, nsError.code == 3164 {
            return Failure.iCloudDownloadRequired
        }
        return Failure.unreadable(error.localizedDescription)
    }

    private func describe(_ url: URL, filename: String, modified: Date?, temporary: Bool) throws -> ExportedMedia {
        if temporary {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw Failure.unreadable("the file is empty") }
        return ExportedMedia(url: url, filename: filename.isEmpty ? url.lastPathComponent : filename,
                             modified: modified ?? values?.contentModificationDate ?? Date(),
                             byteCount: size, temporary: temporary)
    }
}

/// Photo library permission, kept separate so the picker can be used without it
/// and the asset path can simply be skipped when it is not granted.
enum MediaLibrary {
    static var isReadable: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    @discardableResult
    static func requestReadAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Prefer asset identifiers so filenames and capture dates survive; fall
    /// back to the item provider for a lazy copy when the library is off limits.
    static func sources(forPickerResults results: [PHPickerResult]) -> [MediaSource] {
        let readable = isReadable
        return results.map { result in
            if readable, let identifier = result.assetIdentifier { return .asset(localIdentifier: identifier) }
            return .picked(PickedItem(result.itemProvider))
        }
    }
}

extension PHAssetResourceManager {
    func writeData(for resource: PHAssetResource, toFile url: URL, options: PHAssetResourceRequestOptions) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let writeFailure = PhotoResourceWriteFailure()
        let cancellation = PhotoResourceRequestCancellation(manager: self)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = self.requestData(for: resource, options: options) { data in
                    do { try handle.write(contentsOf: data) }
                    catch { writeFailure.record(error); cancellation.cancel() }
                } completionHandler: { error in
                    if let failure = writeFailure.error { continuation.resume(throwing: failure) }
                    else if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }
}

/// SHA-1 fed from PhotoKit's data callbacks, which arrive on its own queue.
private final class StreamingSHA1: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = Insecure.SHA1()

    func update(_ data: Data) {
        lock.lock(); hasher.update(data: data); lock.unlock()
    }

    func finalize() -> Data {
        lock.lock(); defer { lock.unlock() }
        return Data(hasher.finalize())
    }
}

private final class PhotoResourceWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
}

private final class PhotoResourceRequestCancellation: @unchecked Sendable {
    private let manager: PHAssetResourceManager
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false

    init(manager: PHAssetResourceManager) { self.manager = manager }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelDataRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelDataRequest(requestID) }
    }
}

/// Gathers a small resource's bytes as `requestData` delivers them.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
}
