import SwiftUI

@main
struct PhotosBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var log: ProbeLog
    @StateObject private var connector: AccountConnector
    @StateObject private var account: PhotosAccount
    @StateObject private var queue: UploadQueue
    @StateObject private var preferences: BackupPreferences
    @StateObject private var albums: PhotoAlbumStore
    @Environment(\.scenePhase) private var scenePhase
    private let network: NetworkPolicyMonitor
    private let automaticBackup: AutomaticBackupCoordinator

    init() {
        let sharedLog = ProbeLog()
        let sharedConnector = AccountConnector(log: sharedLog)
        let stack = PhotosStack()
        let preferences = BackupPreferences()
        let albums = PhotoAlbumStore()
        let network = NetworkPolicyMonitor()
        stack.queue.options.storageSaver = preferences.storageSaver
        stack.queue.options.useQuota = preferences.useQuota
        stack.queue.setMaxConcurrent(preferences.concurrentUploads)
        let automaticBackup = AutomaticBackupCoordinator(
            photos: stack,
            account: stack.account,
            queue: stack.queue,
            preferences: preferences,
            albums: albums,
            network: network
        )
        BackgroundFileUploadTransport.shared.setEventsDrainer { [weak automaticBackup] in
            await automaticBackup?.handleBackgroundURLSessionEvents()
        }
        // A successful exchange is what connects the account; the connector owns
        // the token, the stack owns everything downstream of it.
        sharedConnector.onExchange = { [weak stack] result in await stack?.connect(result) }
        _log = StateObject(wrappedValue: sharedLog)
        _connector = StateObject(wrappedValue: sharedConnector)
        _account = StateObject(wrappedValue: stack.account)
        _queue = StateObject(wrappedValue: stack.queue)
        _preferences = StateObject(wrappedValue: preferences)
        _albums = StateObject(wrappedValue: albums)
        self.network = network
        self.automaticBackup = automaticBackup
        if #available(iOS 16.0, *) {
            BackupShortcutBridge.coordinator = automaticBackup
        }
        network.onStatusChange = { [weak automaticBackup] status in
            DiagnosticEventLog.shared.record("network", "Connection changed to \(status.diagnosticLabel)")
            automaticBackup?.networkDidChange()
        }
        network.start()
        automaticBackup.applyNetworkPolicy()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(log)
                .environmentObject(connector)
                .environmentObject(account)
                .environmentObject(queue)
                .environmentObject(preferences)
                .environmentObject(albums)
                .environmentObject(automaticBackup)
                .task { await automaticBackup.start() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        AppSessionTracker.note(.active)
                        automaticBackup.applicationDidBecomeActive()
                    case .inactive:
                        AppSessionTracker.note(.inactive)
                    case .background:
                        AppSessionTracker.note(.background)
                        automaticBackup.applicationDidEnterBackground()
                    @unknown default:
                        break
                    }
                }
                // Settings changes are logged here, where each one is applied,
                // so a report shows what the user changed and when.
                .onChange(of: preferences.connection) { value in
                    DiagnosticEventLog.shared.record("settings", "Connection set to \(value.title)")
                    automaticBackup.connectionPreferenceDidChange()
                }
                .onChange(of: preferences.storageSaver) { value in
                    DiagnosticEventLog.shared.record("settings", "Storage Saver turned \(value ? "on" : "off")")
                    queue.options.storageSaver = value
                }
                .onChange(of: preferences.useQuota) { value in
                    DiagnosticEventLog.shared.record("settings", "Count Against Storage Quota turned \(value ? "on" : "off")")
                    queue.options.useQuota = value
                }
                .onChange(of: preferences.concurrentUploads) { value in
                    DiagnosticEventLog.shared.record("settings", "Simultaneous uploads set to \(value)")
                    queue.setMaxConcurrent(value)
                }
                .onChange(of: preferences.automaticBackup) { value in
                    DiagnosticEventLog.shared.record("settings", "Automatic Backup turned \(value ? "on" : "off")")
                    automaticBackup.backupConfigurationDidChange()
                }
                .onChange(of: preferences.selectedAlbumIDs) { value in
                    DiagnosticEventLog.shared.record("settings", "Album selection changed; \(value.count) selected")
                    automaticBackup.backupConfigurationDidChange()
                }
                .onChange(of: preferences.completedOnboarding) { value in
                    if value { DiagnosticEventLog.shared.record("settings", "Finished onboarding") }
                    automaticBackup.backupConfigurationDidChange()
                }
                .onChange(of: account.status) { _ in automaticBackup.accountDidChange() }
        }
    }
}
