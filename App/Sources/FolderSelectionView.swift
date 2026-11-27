import Photos
import SwiftUI
import UIKit

struct FolderSelectionView: View {
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.openURL) private var openURL
    @State private var searchText = ""

    private func refreshBackedUpCounts() {
        albums.refreshBackedUpCounts(for: preferences.selectedAlbumIDs,
                                     mediaFilter: preferences.mediaFilter,
                                     cutoffDate: preferences.backupCutoffDate,
                                     isBackedUp: queue.backedUpAssetLookup())
    }

    private var filteredAlbums: [PhotoAlbum] {
        guard !searchText.isEmpty else { return albums.albums }
        return albums.albums.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            Group {
                if albums.authorization == .notDetermined {
                    permissionState
                } else if !albums.canRead {
                    deniedState
                } else if albums.isLoading {
                    ProgressView("Loading albums…")
                } else if albums.albums.isEmpty {
                    EmptyState(symbol: "rectangle.stack", title: "No albums found", message: "Albums from your Photos library will appear here.")
                } else {
                    albumList
                }
            }
            .background(BackupTheme.background)
            .navigationTitle("Albums")
            .searchable(text: $searchText, prompt: "Search albums")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(preferences.selectedAlbumIDs.count) selected")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .onAppear {
                albums.refreshInBackground()
                refreshBackedUpCounts()
            }
            .onChange(of: preferences.selectedAlbumIDs) { _ in refreshBackedUpCounts() }
            .onChange(of: preferences.mediaFilter) { _ in refreshBackedUpCounts() }
            .onChange(of: preferences.backupFromDateEnabled) { _ in refreshBackedUpCounts() }
            .onChange(of: preferences.backupFromDate) { _ in
                if preferences.backupFromDateEnabled { refreshBackedUpCounts() }
            }
            .onChange(of: albums.albums) { _ in refreshBackedUpCounts() }
            // The completion ledger, not the rows: `items` changes on every
            // progress tick, and each of those kicked off a fresh enumeration of
            // every asset in every selected album. Only a finished upload can
            // move a "N of M backed up" count.
            .onChange(of: queue.completedSourceKeys) { _ in refreshBackedUpCounts() }
        }
        .navigationViewStyle(.stack)
    }

    private var albumList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if albums.isLimited { limitedAccessBanner }
                HStack(spacing: 10) {
                    Image(systemName: preferences.automaticBackup ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(preferences.automaticBackup ? .green : .orange)
                    Text(preferences.automaticBackup ? "Selected albums back up automatically" : "Automatic backup is paused")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(14)
                .background((preferences.automaticBackup ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 4)

                ForEach(filteredAlbums) { album in
                    AlbumSelectionRow(album: album,
                                      isSelected: preferences.selectedAlbumIDs.contains(album.id),
                                      backedUpCount: albums.backedUpCounts[album.id],
                                      eligibleCount: albums.eligibleCounts[album.id]) {
                        preferences.toggle(albumID: album.id)
                    }
                }
            }
            .padding(16)
        }
    }

    /// Under limited access every PhotoKit fetch is scoped to the assets the
    /// user hand-picked, so "All Photos" can read as a few dozen items with no
    /// explanation. Say so, and offer the way to change it.
    private var limitedAccessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "photo.badge.checkmark").foregroundStyle(.orange)
                Text("Limited photo access").font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text("Only the photos you picked are visible to Photos Backup, so these counts do not cover your whole library.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Change in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 4)
    }

    private var permissionState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.on.rectangle.angled", title: "See your albums", message: "Allow photo access to choose which albums Photos Backup should protect.")
            Button("Allow Photo Access") { Task { await albums.requestAccess() } }
                .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }

    private var deniedState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "Allow access in Settings to choose albums and back up photos.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }
}
