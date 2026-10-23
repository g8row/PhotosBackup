import Foundation
import UniformTypeIdentifiers

/// Folders picked from the Files app (On My iPhone, iCloud Drive, a file
/// provider), remembered as bookmarks so queued items from them can still be
/// read after a relaunch. A URL from the folder picker is security-scoped: its
/// files are reachable only between `startAccessingSecurityScopedResource` and
/// the matching stop, and only through a bookmark once the process has died.
///
/// Queue rows name a folder by its id here plus a path inside it, never by an
/// absolute URL, because a resolved bookmark can point somewhere new.
final class PickedFolderStore: @unchecked Sendable {
    struct Folder: Codable, Equatable {
        let id: String
        /// The picked folder's own name, the album its top-level files go into.
        let name: String
        var bookmark: Data
    }

    enum Failure: LocalizedError, Equatable {
        case unknownFolder
        case accessDenied
        var errorDescription: String? {
            switch self {
            case .unknownFolder: return "The folder this item came from is no longer known to the app. Pick the folder again."
            case .accessDenied: return "The app no longer has access to the folder this item came from. Pick the folder again."
            }
        }
    }

    static let shared = PickedFolderStore()

    private let lock = NSLock()
    private let url: URL
    private var folders: [String: Folder]

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotosBackup", isDirectory: true)
            .appendingPathComponent("picked-folders-v1.json")
        folders = (try? Data(contentsOf: self.url))
            .flatMap { try? JSONDecoder().decode([String: Folder].self, from: $0) } ?? [:]
    }

    func folder(_ id: String) -> Folder? {
        lock.lock(); defer { lock.unlock() }
        return folders[id]
    }

    /// Remember a picked folder and return its id. The caller must already be
    /// accessing `folderURL`. Picking the same folder again reuses its id, so
    /// its items keep their queue and completion keys and are not re-queued.
    func register(_ folderURL: URL) throws -> String {
        let bookmark = try folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let path = folderURL.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        let existing = folders.values.first { folder in
            var stale = false
            return (try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                             bookmarkDataIsStale: &stale))?.standardizedFileURL.path == path
        }
        let id = existing?.id ?? UUID().uuidString
        folders[id] = Folder(id: id, name: folderURL.lastPathComponent, bookmark: bookmark)
        try saveLocked()
        return id
    }

    /// Run `body` with the folder's URL while access to it is held.
    func withAccess<T>(to id: String, _ body: (URL) throws -> T) throws -> T {
        guard let folder = folder(id) else { throw Failure.unknownFolder }
        var stale = false
        guard let folderURL = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                                       bookmarkDataIsStale: &stale) else { throw Failure.accessDenied }
        // False for a folder the app can already read (its own container), so
        // only a held access is released; a folder that really is out of reach
        // fails at the read instead.
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        if stale, let renewed = try? folderURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            lock.lock()
            folders[id]?.bookmark = renewed
            try? saveLocked()
            lock.unlock()
        }
        return try body(folderURL)
    }

    /// The album a file goes into: its immediate parent folder's name, as the
    /// desktop app files it. A file at the top of the picked folder takes the
    /// picked folder's own name.
    func albumName(folderID: String, relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty { return (parent as NSString).lastPathComponent }
        return folder(folderID)?.name
    }

    private func saveLocked() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(folders).write(to: url, options: .atomic)
        // Readable after first unlock, so a background window can export.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

enum FolderScanner {
    /// iCloud Drive can list a file that is not downloaded yet as a hidden
    /// `.<name>.icloud` placeholder. Returns the real name, or nil for anything
    /// else.
    static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Whether a filename is a photo or video, judged by its extension.
    static func isMedia(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// Register a folder from the picker and list every photo and video under
    /// it, in path order. Blocking file-system work: call it off the main actor.
    static func sources(inPickedFolder folderURL: URL,
                        store: PickedFolderStore = .shared) throws -> [MediaSource] {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        let folderID = try store.register(folderURL)
        // The path form hands back paths relative to the folder, which is
        // exactly what a queue row stores.
        guard let enumerator = FileManager.default.enumerator(atPath: folderURL.path) else { return [] }
        var paths: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let isDirectory = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            var name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") {
                // Skip hidden folders outright; keep only iCloud placeholders.
                if isDirectory { enumerator.skipDescendants(); continue }
                guard let real = placeholderName(name) else { continue }
                name = real
            } else if isDirectory {
                continue
            }
            guard isMedia(name) else { continue }
            let directory = (relative as NSString).deletingLastPathComponent
            paths.append(directory.isEmpty ? name : directory + "/" + name)
        }
        return paths.sorted().map { .folderFile(folderID: folderID, relativePath: $0) }
    }
}
