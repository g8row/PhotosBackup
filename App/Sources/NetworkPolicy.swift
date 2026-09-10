import Foundation
import Network

enum BackupNetworkStatus: Equatable, Sendable {
    case checking
    case unavailable
    case wifi
    case cellular
    case wired
    case other

    init(path: NWPath) {
        guard path.status == .satisfied else {
            self = .unavailable
            return
        }
        if path.usesInterfaceType(.wifi) { self = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { self = .wired }
        else if path.usesInterfaceType(.cellular) { self = .cellular }
        else { self = .other }
    }
}

extension BackupNetworkStatus {
    var diagnosticLabel: String {
        switch self {
        case .checking: return "checking"
        case .unavailable: return "unavailable"
        case .wifi: return "Wi-Fi"
        case .cellular: return "cellular"
        case .wired: return "wired"
        case .other: return "other"
        }
    }
}

struct NetworkPolicyDecision: Equatable, Sendable {
    let allowsUploads: Bool
    let pauseReason: String?

    static let allowed = NetworkPolicyDecision(allowsUploads: true, pauseReason: nil)
}

extension BackupConnection {
    func decision(for status: BackupNetworkStatus) -> NetworkPolicyDecision {
        switch status {
        case .checking:
            return NetworkPolicyDecision(allowsUploads: false, pauseReason: "Checking the network connection…")
        case .unavailable:
            return NetworkPolicyDecision(allowsUploads: false, pauseReason: "Waiting for a network connection")
        case .wifi, .wired:
            return .allowed
        case .cellular, .other:
            if self == .wifiAndCellular { return .allowed }
            return NetworkPolicyDecision(allowsUploads: false, pauseReason: "Waiting for Wi-Fi")
        }
    }
}

/// Publishes coarse transport changes without owning any backup policy. Keeping
/// the policy pure makes it deterministic in tests and lets Settings changes be
/// applied immediately without restarting the monitor.
@MainActor
final class NetworkPolicyMonitor: ObservableObject {
    @Published private(set) var status: BackupNetworkStatus = .checking
    var onStatusChange: ((BackupNetworkStatus) -> Void)?

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.g8row.photosbackup.network-policy")
    private var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next = BackupNetworkStatus(path: path)
            Task { @MainActor [weak self] in
                guard let self, self.status != next else { return }
                self.status = next
                self.onStatusChange?(next)
            }
        }
        monitor.start(queue: queue)
    }

    func waitForInitialStatus() async -> BackupNetworkStatus {
        for _ in 0..<40 where status == .checking {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return status
    }

    deinit { monitor.cancel() }
}
