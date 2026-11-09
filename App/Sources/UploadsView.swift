import SwiftUI

struct UploadsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @State private var showPicker = false
    @State private var showingStopBackupConfirmation = false
    @State private var inspectedFailure: FailureDetail?

    /// A failed row's full text, snapshotted when it is tapped. The row itself
    /// can be retried or cleared while the sheet is open.
    private struct FailureDetail: Identifiable {
        let id: UUID
        let name: String
        let reason: String
    }

    var body: some View {
        NavigationView {
            List {
                manualBackupSection
                if let reason = queue.pauseReason { pausedSection(reason) }
                if let warning = queue.persistenceWarning { persistenceWarningSection(warning) }
                if queue.items.isEmpty { emptySection }
                else {
                    queueManagementSection
                    activitySection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { sources in enqueue(sources) }.ignoresSafeArea()
            }
            .sheet(item: $inspectedFailure) { failure in failureSheet(failure) }
            .confirmationDialog(
                "Stop all backups?",
                isPresented: $showingStopBackupConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop Backup", role: .destructive) { stopBackup() }
                Button("Keep Backing Up", role: .cancel) {}
            } message: {
                Text(stopBackupMessage)
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Photos picked by hand are checked against Google even when the app
    /// remembers them as backed up: picking one is how someone asks "is this
    /// really backed up?", and the hash lookup settles it without re-uploading
    /// anything Google already has.
    private func enqueue(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        queue.reverify(sources)
    }

    private var manualBackupSection: some View {
        Section {
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "photo.badge.plus", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose Photos or Videos").font(.headline).foregroundStyle(.primary)
                        Text("Back up to 50 items at once").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(!account.status.isUsable)
        } footer: {
            if !account.status.isUsable { Text("Connect a Google Photos account before starting a backup.") }
        }
    }

    private func pausedSection(_ reason: String) -> some View {
        Section {
            Label("Backup Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            Text(reason).font(.footnote).foregroundStyle(.secondary)
            if queue.haltReason != nil {
                Button("Resume Backup") { queue.resume() }.disabled(!account.status.isUsable)
            } else if queue.isUserPaused {
                Button("Resume Backup") { queue.resumeUserPausedUploads() }
                    .disabled(!account.status.isUsable)
            }
        }
    }

    private var queueManagementSection: some View {
        Section("Queue Controls") {
            if queue.activeCount > 0 || queue.isUserPaused {
                if queue.isUserPaused {
                    Button {
                        queue.resumeUserPausedUploads()
                    } label: {
                        Label("Resume Backup", systemImage: "play.circle")
                    }
                    .disabled(!account.status.isUsable)
                } else if queue.pauseReason == nil {
                    Button {
                        queue.pauseAfterCurrentUploads()
                    } label: {
                        Label("Pause After Current Uploads", systemImage: "pause.circle")
                    }
                }

                if queue.activeCount > 0 {
                    Button(role: .destructive) {
                        showingStopBackupConfirmation = true
                    } label: {
                        Label("Stop Backup", systemImage: "stop.circle")
                    }
                }
            }

            if queue.failedCount > 0 {
                Button {
                    queue.retryAllFailed()
                } label: {
                    Label("Retry Failed Uploads", systemImage: "arrow.clockwise.circle")
                }
            }

            if queue.hasFinishedItems {
                Button {
                    queue.clearFinished()
                } label: {
                    Label("Clear Finished Uploads", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func persistenceWarningSection(_ warning: String) -> some View {
        Section {
            Label("Upload Progress Isn’t Saved", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(warning).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptySection: some View {
        Section {
            EmptyState(symbol: "tray", title: "No backup activity", message: "Photos you back up manually or from selected albums will appear here.")
                .listRowBackground(Color.clear)
        }
    }

    private var activitySection: some View {
        Section {
            if !queue.isIdle {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Overall Progress").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(queue.overallFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: queue.overallFraction).tint(BackupTheme.blue)
                }
                .padding(.vertical, 6)
            }
            ForEach(listed.items) { item in activityRow(item) }
        } header: {
            HStack {
                Text("Uploads")
                Spacer()
                if !queue.isIdle { Text("\(queue.activeCount) remaining") }
            }
        } footer: {
            let notes = [
                listed.hiddenQueued > 0 ? "\(listed.hiddenQueued.formatted()) more waiting their turn." : nil,
                listed.hiddenFinished > 0 ? "\(listed.hiddenFinished.formatted()) older finished items not shown." : nil,
                queue.deferredForICloudCount > 0
                    ? "\(queue.deferredForICloudCount) items need to download from iCloud first. Keep the app open to finish them."
                    : nil,
            ].compactMap { $0 }
            if !notes.isEmpty { Text(notes.joined(separator: " ")) }
        }
    }

    private var listed: ActivityListing { ActivityListing(queue.items) }

    private var stopBackupMessage: String {
        if preferences.automaticBackup {
            return "Uploads in progress will be cancelled, the queue will be cleared, and Automatic Backup will be turned off. Photos already backed up are not affected."
        }
        return "Uploads in progress will be cancelled and the queue will be cleared. Photos already backed up are not affected."
    }

    private func stopBackup() {
        preferences.automaticBackup = false
        queue.cancelAll()
    }

    private func activityRow(_ item: UploadItem) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol(item.state), color: tint(item.state), size: 42)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if item.byteCount > 0 {
                        Text(item.byteCount.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if case .failed = item.state {
                    // The reason above is clamped to two lines, and Google's
                    // own explanation is usually past the clamp.
                    Text("Tap for details").font(.caption2).foregroundStyle(BackupTheme.blue)
                }
                if let fraction = item.state.fraction, item.state.isWorking {
                    ProgressView(value: fraction).tint(BackupTheme.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard case .failed(let reason, _) = item.state else { return }
            inspectedFailure = FailureDetail(id: item.id, name: item.name, reason: reason)
        }
        .swipeActions {
            if item.state.isFinished {
                if item.state != .done && item.state != .alreadyBackedUp {
                    Button("Retry") { queue.retry(item.id) }.tint(BackupTheme.blue)
                }
            } else {
                Button("Cancel", role: .destructive) { queue.cancel(item.id) }
            }
        }
    }

    /// The whole reason, selectable and copyable. A support report is only as
    /// good as the text the reporter can actually get out of the app.
    private func failureSheet(_ failure: FailureDetail) -> some View {
        NavigationView {
            List {
                Section("Item") { Text(failure.name).font(.subheadline) }
                Section("What Google said") {
                    Text(failure.reason)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button {
                        UIPasteboard.general.string = "\(failure.name)\n\(failure.reason)"
                    } label: {
                        Label("Copy Details", systemImage: "doc.on.doc")
                    }
                    Button {
                        queue.retry(failure.id)
                        inspectedFailure = nil
                    } label: {
                        Label("Retry This Item", systemImage: "arrow.clockwise")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Upload Failed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { inspectedFailure = nil }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func symbol(_ state: UploadItem.State) -> String {
        switch state {
        case .done, .alreadyBackedUp: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .queued, .waitingToRetry, .waitingForICloud: return "clock"
        default: return "arrow.up"
        }
    }

    private func tint(_ state: UploadItem.State) -> Color {
        switch state {
        case .done, .alreadyBackedUp: return .green
        case .failed: return .red
        case .cancelled, .waitingToRetry, .waitingForICloud: return .orange
        default: return BackupTheme.blue
        }
    }
}

/// The rows the Activity list shows. A whole-library backup queues tens of
/// thousands of rows, and a list that long is drawn and diffed again on every
/// change anywhere in the queue, which is what made the tab slow (#8). Rows
/// in progress or needing a decision always show; of the rest, only the next
/// few waiting and the latest finished, with the footer counting the others.
struct ActivityListing {
    static let queuedShown = 20
    static let finishedShown = 50

    let items: [UploadItem]
    let hiddenQueued: Int
    let hiddenFinished: Int

    init(_ all: [UploadItem]) {
        var queued: [Int] = []
        var finished: [Int] = []
        var shown = IndexSet()
        for (index, item) in all.enumerated() {
            switch item.state {
            case .queued: queued.append(index)
            case .done, .alreadyBackedUp: finished.append(index)
            default: shown.insert(index)
            }
        }
        queued.prefix(Self.queuedShown).forEach { shown.insert($0) }
        finished.suffix(Self.finishedShown).forEach { shown.insert($0) }
        items = shown.map { all[$0] }
        hiddenQueued = max(0, queued.count - Self.queuedShown)
        hiddenFinished = max(0, finished.count - Self.finishedShown)
    }
}
