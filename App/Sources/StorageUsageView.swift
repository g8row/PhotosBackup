import SwiftUI
import UniformTypeIdentifiers

struct StorageUsageView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @State private var snapshot: AppStorageSnapshot?
    @State private var isCleaning = false
    @State private var exportDocument: BackupHistoryDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var historyMessage: String?

    var body: some View {
        List {
            Section("Used by Photos Backup") {
                storageRow("Pending upload copies", bytes: snapshot?.stagedUploads)
                storageRow("Backup history and queue", bytes: snapshot?.backupRecords)
                storageRow("Completed transfer receipts", bytes: snapshot?.transferResults)
            }

            Section("System-managed") {
                storageRow("Network and web caches", bytes: snapshot?.caches)
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("Export Backup History", systemImage: "square.and.arrow.up")
                }
                .disabled(!account.status.isUsable)

                Button {
                    showImporter = true
                } label: {
                    Label("Import Backup History", systemImage: "square.and.arrow.down")
                }
                .disabled(!account.status.isUsable)

                if let historyMessage {
                    Text(historyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Backup History")
            } footer: {
                Text("Exports the list of items already backed up (and Google album links) as a small JSON file with no credentials or photos. Import it after reinstalling or switching signing certificates to avoid re-checking your whole library.")
            }

            Section {
                Button {
                    cleanUp()
                } label: {
                    HStack {
                        Label("Clean Up Unused Data", systemImage: "sparkles")
                        Spacer()
                        if isCleaning { ProgressView() }
                    }
                }
                .disabled(isCleaning)
            } footer: {
                Text("Cleanup removes caches, old orphaned transfer receipts, and upload copies that are not owned by the current queue. It keeps pending uploads, your Google account, and the small history used to prevent duplicate backups.")
            }

            Section("What is retained") {
                Text("Pending uploads keep a full-size local copy until Google confirms the backup. Large videos are therefore the main source of temporary storage use.")
                Text("Backup history stores account-scoped PhotoKit identifiers. It is much smaller than the media and prevents every scan from uploading the same photos again.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "PhotosBackup-History"
        ) { result in
            switch result {
            case .success:
                historyMessage = "Exported \(queue.completedSourceCount.formatted()) backed-up item records."
                DiagnosticEventLog.shared.record(
                    "storage",
                    "Exported backup history (\(queue.completedSourceKeys.count) ledger keys)"
                )
            case .failure(let error):
                historyMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importHistory(result)
        }
    }

    @ViewBuilder
    private func storageRow(_ title: String, bytes: Int64?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private func cleanUp() {
        guard !isCleaning else { return }
        isCleaning = true
        let files = queue.retainedStagingURLs
        let transferIDs = queue.retainedTransferIDs
        let before = snapshot?.total
        Task {
            await AppStorageUsage.cleanUp(retaining: files, transferIDs: transferIDs)
            await refresh()
            if let before, let after = snapshot?.total {
                DiagnosticEventLog.shared.record(
                    "storage",
                    "Cleaned up unused data; freed \(DiagnosticProcessInfo.bytes(max(0, before - after)))"
                )
            }
            isCleaning = false
        }
    }

    private func prepareExport() {
        guard let email = account.status.email else { return }
        let albums = GoogleAlbumRegistry().albums(for: email)
        let archive = BackupHistoryArchive(
            completedSourceKeys: Array(queue.completedSourceKeys),
            googleAlbums: albums
        )
        do {
            exportDocument = try BackupHistoryDocument(archive: archive)
            historyMessage = nil
            showExporter = true
        } catch {
            historyMessage = "Could not prepare export: \(error.localizedDescription)"
        }
    }

    private func importHistory(_ result: Result<URL, Error>) {
        guard let email = account.status.email else { return }
        switch result {
        case .failure(let error):
            historyMessage = "Could not open that file: \(error.localizedDescription)"
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let archive = try BackupHistoryArchive.decode(data)
                let importedKeys = queue.importCompletedSourceKeys(archive.completedSourceKeys)
                let importedAlbums = (try? GoogleAlbumRegistry().merge(archive.googleAlbums, for: email)) ?? 0
                historyMessage = "Imported \(importedKeys.formatted()) new history record\(importedKeys == 1 ? "" : "s")"
                    + (importedAlbums > 0 ? " and \(importedAlbums.formatted()) album link\(importedAlbums == 1 ? "" : "s")." : ".")
                Task { await refresh() }
            } catch {
                historyMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func refresh() async {
        snapshot = await AppStorageUsage.measure()
    }
}
