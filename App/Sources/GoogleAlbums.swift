import Foundation
import CryptoKit
import Photos

/// Album names -> album media keys this app created, one JSON file per account.
/// Google's private API offers no album lookup, so this record is the only way
/// an album made earlier is found again. Ported from the desktop app's
/// `albums-<slug>.json`.
struct GoogleAlbumRegistry: Sendable {
    private struct Stored: Codable { var albums: [String: String] }
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotosBackup", isDirectory: true)
    }

    /// Named by a hash of the account, so the address stays out of the filename.
    private func url(for account: String) -> URL {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
        let slug = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("google-albums-\(slug).json")
    }

    func albums(for account: String) -> [String: String] {
        guard let data = try? Data(contentsOf: url(for: account)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [:] }
        return stored.albums
    }

    func albumKey(named name: String, for account: String) -> String? {
        albums(for: account)[name]
    }

    /// Pass a nil key to forget an album (deleted in Google Photos, say).
    func save(_ key: String?, named name: String, for account: String) throws {
        var albums = albums(for: account)
        albums[name] = key
        let url = url(for: account)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(Stored(albums: albums)).write(to: url, options: .atomic)
        // Readable after first unlock, like the queue, so a background task
        // running while the phone is locked can still file its uploads.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

/// Files backed-up media into Google Photos albums named after the iOS albums
/// holding them, creating each album the first time its name is seen for the
/// account. An actor so uploads running side by side from one album share a
/// single new album instead of each making their own.
actor GoogleAlbumFiler {
    private let registry: GoogleAlbumRegistry
    /// Album creations in flight, by account and name.
    private var creations: [String: Task<String, Error>] = [:]

    init(registry: GoogleAlbumRegistry = GoogleAlbumRegistry()) {
        self.registry = registry
    }

    /// Titles of the user's own albums holding this asset. Smart albums,
    /// shared albums and albums synced from a computer are left out: the first
    /// are views over the library, and the others are not the user's to file.
    static func localAlbumNames(forAssetIdentifier identifier: String) -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return [] }
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var names: [String] = []
        collections.enumerateObjects { collection, _, _ in
            guard collection.assetCollectionSubtype == .albumRegular,
                  let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, !names.contains(title) else { return }
            names.append(title)
        }
        return names
    }

    /// Put one media item into the album called `name`.
    func file(_ mediaKey: String, intoAlbumNamed name: String, account: String,
              client: GPMCClient, model: String) async throws {
        let slot = account.lowercased() + "\n" + name
        if let pending = creations[slot] {
            try await client.addMediaToAlbum(try await pending.value, mediaKeys: [mediaKey], model: model)
            return
        }
        if let known = registry.albumKey(named: name, for: account) {
            do {
                try await client.addMediaToAlbum(known, mediaKeys: [mediaKey], model: model)
                return
            } catch let error as GPMCError where Self.meansAlbumGone(error) {
                // Another upload may have met the same refusal while this one
                // waited, and already made the replacement.
                if let pending = creations[slot] {
                    try await client.addMediaToAlbum(try await pending.value, mediaKeys: [mediaKey], model: model)
                    return
                }
                if let replacement = registry.albumKey(named: name, for: account), replacement != known {
                    try await client.addMediaToAlbum(replacement, mediaKeys: [mediaKey], model: model)
                    return
                }
                try? registry.save(nil, named: name, for: account)
                DiagnosticEventLog.shared.record(
                    "album", "Google refused a saved album, so a new one will be made: \(error.message)", level: .warning)
            }
        }
        // The new album is created holding this item, as gotohp does.
        let creation = Task { try await client.createAlbum(named: name, mediaKeys: [mediaKey], model: model) }
        creations[slot] = creation
        defer { creations[slot] = nil }
        let key = try await creation.value
        do {
            try registry.save(key, named: name, for: account)
            DiagnosticEventLog.shared.record("album", "Created a Google Photos album for an iOS album")
        } catch {
            // The item is in the album; only the record is lost, so the next
            // upload from this album makes a second one. Say so rather than
            // fail an upload that succeeded.
            DiagnosticEventLog.shared.record(
                "album", "Created an album but could not save its key: \(error.localizedDescription)", level: .error)
        }
    }

    /// A permanent refusal most likely means the album was deleted in Google
    /// Photos. Transient and credential errors go to the queue's usual handling.
    private static func meansAlbumGone(_ error: GPMCError) -> Bool {
        guard case .server = error.kind else { return false }
        return !error.isRetryable
    }
}
