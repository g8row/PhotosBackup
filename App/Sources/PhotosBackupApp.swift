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
    @StateObject private var dailyBudget: DailyUploadTracker
    @Environment(\.scenePhase) private var scenePhase
    private let network: NetworkPolicyMonitor
    private let power: PowerPolicyMonitor
    private let automaticBackup: AutomaticBackupCoordinator

    init() {
        let sharedLog = ProbeLog()
        let sharedConnector = AccountConnector(log: sharedLog)
        let stack = PhotosStack()
        let preferences = BackupPreferences()
        let albums = PhotoAlbumStore()
        let dailyBudget = DailyUploadTracker()
        let network = NetworkPolicyMonitor()
        let power = PowerPolicyMonitor()
        stack.queue.options.storageSaver = preferences.storageSaver
        stack.queue.options.useQuota = preferences.useQuota
        stack.queue.options.filesIntoAlbums = preferences.albumsFromLibrary
        stack.queue.setMaxConcurrent(preferences.concurrentUploads)
        let automaticBackup = AutomaticBackupCoordinator(
            photos: stack,
            account: stack.account,
            queue: stack.queue,
            preferences: preferences,
            albums: albums,
            network: network,
            power: power,
            dailyBudget: dailyBudget
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
        _dailyBudget = StateObject(wrappedValue: dailyBudget)
        self.network = network
        self.power = power
        self.automaticBackup = automaticBackup
        if #available(iOS 16.0, *) {
            BackupShortcutBridge.coordinator = automaticBackup
        }
        network.onStatusChange = { [weak automaticBackup] status in
            DiagnosticEventLog.shared.record("network", "Connection changed to \(status.diagnosticLabel)")
            automaticBackup?.networkDidChange()
        }
        network.start()
        power.onStatusChange = { [weak automaticBackup] status in
            DiagnosticEventLog.shared.record("power", "Power changed to \(status.diagnosticLabel)")
            automaticBackup?.powerDidChange()
        }
        power.start()
        automaticBackup.applyNetworkPolicy()
        automaticBackup.applyPowerPolicy()
        automaticBackup.applyDailyLimitPolicy()
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
                .environmentObject(dailyBudget)
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
                .onChange(of: preferences.albumsFromLibrary) { value in
                    DiagnosticEventLog.shared.record("settings", "Add to Matching Albums turned \(value ? "on" : "off")")
                    queue.options.filesIntoAlbums = value
                }
                .onChange(of: preferences.backUpLivePhotoMotion) { value in
                    DiagnosticEventLog.shared.record("settings", "Back Up Live Photo Motion turned \(value ? "on" : "off")")
                    automaticBackup.livePhotoMotionPreferenceDidChange()
                }
                .onChange(of: preferences.backUpEditedPhotoOriginals) { value in
                    DiagnosticEventLog.shared.record("settings", "Back Up Edited Photo Originals turned \(value ? "on" : "off")")
                    automaticBackup.editedPhotoOriginalsPreferenceDidChange()
                }
                .onChange(of: preferences.mediaFilter) { value in
                    DiagnosticEventLog.shared.record("settings", "Media Types set to \(value.title)")
                    automaticBackup.backupConfigurationDidChange()
                }
                .onChange(of: preferences.backupFromDateEnabled) { value in
                    DiagnosticEventLog.shared.record("settings", "Only Back Up After Date turned \(value ? "on" : "off")")
                    automaticBackup.backupConfigurationDidChange()
                }
                .onChange(of: preferences.backupFromDate) { _ in
                    if preferences.backupFromDateEnabled {
                        DiagnosticEventLog.shared.record("settings", "Backup cutoff date updated")
                        automaticBackup.backupConfigurationDidChange()
                    }
                }
                .onChange(of: preferences.dailyUploadLimitBytes) { value in
                    DiagnosticEventLog.shared.record("settings", "Daily Upload Limit set to \(DailyUploadBudget.label(for: value))")
                    automaticBackup.dailyUploadLimitDidChange()
                }
                .onChange(of: preferences.keepAliveEnabled) { value in
                    DiagnosticEventLog.shared.record("settings", "Keep Running in Background turned \(value ? "on" : "off")")
                    automaticBackup.keepAlivePreferenceDidChange()
                }
                .onChange(of: preferences.keepAliveMode) { value in
                    DiagnosticEventLog.shared.record("settings", "Keep-alive mode set to \(value.title)")
                    automaticBackup.keepAlivePreferenceDidChange()
                }
                .onChange(of: preferences.onlyWhileCharging) { value in
                    DiagnosticEventLog.shared.record("settings", "Only While Charging turned \(value ? "on" : "off")")
                    automaticBackup.powerPreferenceDidChange()
                }
                .onChange(of: preferences.minimumBatteryPercent) { value in
                    DiagnosticEventLog.shared.record("settings", "Minimum battery set to \(value == 0 ? "off" : "\(value)%")")
                    automaticBackup.powerPreferenceDidChange()
                }
                .onChange(of: preferences.significantLocationWake) { value in
                    DiagnosticEventLog.shared.record("settings", "Wake on Location Change turned \(value ? "on" : "off")")
                    automaticBackup.significantLocationWakePreferenceDidChange()
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
