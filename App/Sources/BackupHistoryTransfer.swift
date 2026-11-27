import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Portable, privacy-safe backup history archive for Settings → Storage
/// (issue #34). Stores only the local completion ledger keys and Google album
/// key mappings — never credentials, email addresses, or media files — so
/// reinstalling the app or switching sideloading certificates does not force
/// a full library re-check.
struct BackupHistoryArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let completedSourceKeys: [String]
    let googleAlbums: [String: String]

    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "This backup history file uses a newer format (version \(version)) than this version of Photos Backup can read."
            case .invalidFormat:
                return "That file is not a Photos Backup history export."
            }
        }
    }

    init(
        completedSourceKeys: [String],
        googleAlbums: [String: String] = [:],
        exportedAt: Date = Date(),
        version: Int = currentVersion
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.completedSourceKeys = Array(Set(completedSourceKeys)).sorted()
        self.googleAlbums = googleAlbums
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BackupHistoryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: BackupHistoryArchive
        do {
            archive = try decoder.decode(BackupHistoryArchive.self, from: data)
        } catch {
            throw Failure.invalidFormat
        }
        guard archive.version <= currentVersion, archive.version >= 1 else {
            throw Failure.unsupportedVersion(archive.version)
        }
        return archive
    }
}

struct BackupHistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(archive: BackupHistoryArchive) throws {
        data = try archive.encode()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupHistoryArchive.Failure.invalidFormat
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
