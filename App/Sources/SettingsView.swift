import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator

    let showTutorial: () -> Void
    @State private var confirmDisconnect = false
    @State private var connectionCheckResult: PhotosAccount.VerificationOutcome?
    @State private var verifyMessage: String?
    @State private var isVerifying = false
    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!

    var body: some View {
        NavigationView {
            Form {
                accountSection
                backupSection
                automationSection
                verifySection
                supportSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect Google Photos?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New backups will stop until you connect again. Photos already backed up are not affected.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var accountSection: some View {
        Section("Google Photos Account") {
            HStack(alignment: .top, spacing: 12) {
                FeatureIcon(symbol: "person.crop.circle.fill", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(account.status.isUsable ? Color.green : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer()
                Image(systemName: account.status.isUsable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(account.status.isUsable ? Color.green : Color.orange)
                    .accessibilityLabel(account.status.isUsable ? "Connected" : "Action needed")
            }
            .padding(.vertical, 4)

            if account.status.isUsable {
                Button {
                    connectionCheckResult = nil
                    Task {
                        let result = await account.verify()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            connectionCheckResult = result
                        }
                    }
                } label: {
                    HStack {
                        Text(account.verifying ? "Checking Connection…" : "Check Connection")
                        Spacer()
                        if account.verifying {
                            ProgressView()
                        } else if connectionCheckResult == .succeeded {
                            Label("Verified", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                    .disabled(account.verifying)
                Button("Disconnect Account", role: .destructive) { confirmDisconnect = true }
            } else {
                Button("Connect Account") { showTutorial() }
            }

            if case .failed(let reason) = connectionCheckResult, account.status.isUsable {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if account.status.isUsable, let warning = account.persistenceWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Not saved to Keychain", systemImage: "key.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(warning + " The account works for this session but may need to be connected again after relaunch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: account.status) { status in
            if !status.isUsable { connectionCheckResult = nil }
        }
    }

    private var backupSection: some View {
        Section {
            Toggle("Automatic Backup", isOn: $preferences.automaticBackup)
            Picker("Use Connection", selection: $preferences.connection) {
                ForEach(BackupConnection.allCases) { option in Text(option.title).tag(option) }
            }
            if let reason = queue.networkPauseReason {
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Picker("Simultaneous Uploads", selection: $preferences.concurrentUploads) {
                ForEach(Array(UploadQueue.concurrencyRange), id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            }
            Toggle("Storage Saver", isOn: $preferences.storageSaver)
            Toggle("Count Against Storage Quota", isOn: $preferences.useQuota)
        } header: {
            Text("Backup")
        } footer: {
            Text("More simultaneous uploads finish a large backup sooner. Each one stages a full-size copy on the device while it runs, so high values use more storage, battery and data at once — 2 suits most phones. Lowering it lets uploads already running finish first.\n\nStorage Saver asks Google Photos to reduce file size. With Count Against Storage Quota off, uploads identify as an older Pixel phone so they don't use your Google storage; the Google Photos app may then label them “Storage saver” even though the original file was kept. The file size, or Google Photos on the web, shows the real quality. Live Photos currently back up as still images.")
        }
    }

    private var verifySection: some View {
        Section {
            Button {
                runVerification()
            } label: {
                HStack {
                    Text(isVerifying ? "Re-checking…" : "Re-check Backups")
                    Spacer()
                    if isVerifying { ProgressView() }
                }
            }
            .disabled(!canVerify)
            if let verifyMessage {
                Text(verifyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Re-check")
        } footer: {
            Text("Compares your selected albums against Google Photos again. Items still in the cloud finish quickly; anything deleted there is queued for upload again.")
        }
    }

    private var automationSection: some View {
        Section {
            ShortcutsSettingsRows()
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("In the Shortcuts app, create a personal automation — when the iPhone connects to power, at a time of day, or when it joins your home Wi-Fi — set it to run immediately, and add Back Up Photos. Each run has about 30 seconds: it finds new photos in the selected albums and hands them to iOS to upload in the background. It runs even with Automatic Backup off, and still follows Use Connection and Pause. Photos stored only in iCloud wait until the app is open.")
        }
    }

    private var canVerify: Bool {
        account.status.isUsable && !isVerifying && !preferences.selectedAlbumIDs.isEmpty
    }

    private func runVerification() {
        guard canVerify else { return }
        isVerifying = true
        verifyMessage = nil
        Task {
            let outcome = await automaticBackup.reverifySelectedAlbums()
            isVerifying = false
            verifyMessage = DashboardView.message(for: outcome)
        }
    }

    private var supportSection: some View {
        Section("Support") {
            NavigationLink("Create Diagnostic Report") { DiagnosticReportView() }
            NavigationLink("Storage") { StorageUsageView() }
            NavigationLink("Diagnostics") { DiagnosticsView() }
            Button("Run Onboarding Again") {
                preferences.resetOnboarding()
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledRow("App", value: "Photos Backup")
            LabeledRow("Version", value: appVersion)
            LabeledRow("iOS", value: UIDevice.current.systemVersion)
            LabeledRow("Core technology") {
                Link("GPMC by xob0t", destination: gpmcURL)
            }
        }
    }

    private var accountTitle: String {
        switch account.status {
        case .loading: return "Checking account…"
        case .disconnected: return "Not connected"
        case .connected(let email, _): return email
        case .rejected(let email, _): return email.isEmpty ? "Sign in again" : email
        }
    }

    private var accountSubtitle: String {
        switch account.status {
        case .loading: return "Looking for a saved credential"
        case .disconnected: return "Connect to start backing up"
        case .connected(_, let since): return "Connected · \(since.formatted(date: .abbreviated, time: .omitted))"
        case .rejected(_, let reason): return reason
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// The Shortcuts rows: a way into the Shortcuts app, and the last run, so an
/// automation can be checked without waiting for a problem.
private struct ShortcutsSettingsRows: View {
    @State private var lastRun: AutomaticBackupRunRecord?

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                Label("Back Up Photos action", systemImage: "square.stack.3d.up.fill")
                Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
                if let lastRun {
                    AutomaticRunRow(run: lastRun)
                } else {
                    Text("The action has not run yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Requires iOS 16 or later", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { lastRun = AutomaticBackupRunHistory.latest(.shortcut) }
    }
}

/// Presents the in-app Google account connection flow (see AccountConnectView)
/// and runs the token exchange on capture. Shown as a sheet from the dashboard
/// and Settings.
struct ConnectionTutorialView: View {
    @EnvironmentObject private var probe: AccountConnector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AccountConnectView(
            onCaptured: { token in
                dismiss()
                Task { await probe.ingestWebToken(token) }
            },
            onCancel: { dismiss() }
        )
    }
}
