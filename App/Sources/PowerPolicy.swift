import Foundation
import UIKit

/// Snapshot of device charging state and battery percentage, kept independent
/// of `UIDevice` so the power policy can be tested deterministically.
struct PowerStatus: Equatable, Sendable {
    /// True when plugged in (`.charging` / `.full`) or when battery state is
    /// unknown (such as on the iOS Simulator, so tests and simulator runs are
    /// never blocked).
    let isCharging: Bool
    /// `0...100`, or `nil` when `UIDevice` cannot report a level (`< 0`).
    let batteryPercent: Int?

    static func current() -> PowerStatus {
        let state = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        let charging = state == .charging || state == .full || state == .unknown
        let percent = level >= 0 ? Int((level * 100).rounded()) : nil
        return PowerStatus(isCharging: charging, batteryPercent: percent)
    }

    var diagnosticLabel: String {
        let chargeText = isCharging ? "charging" : "unplugged"
        guard let batteryPercent else { return chargeText }
        return "\(batteryPercent)% (\(chargeText))"
    }
}

struct PowerPolicyDecision: Equatable, Sendable {
    let allowsUploads: Bool
    let pauseReason: String?

    static let allowed = PowerPolicyDecision(allowsUploads: true, pauseReason: nil)
}

/// Pure policy for "Only While Charging" and "Minimum Battery" (issue #14).
enum PowerPolicy {
    /// Choices shown in Settings (`0` means no minimum battery threshold).
    static let minimumBatteryChoices = [0, 20, 30, 50, 80]

    static func decision(
        onlyWhileCharging: Bool,
        minimumBatteryPercent: Int,
        status: PowerStatus
    ) -> PowerPolicyDecision {
        if onlyWhileCharging, !status.isCharging {
            return PowerPolicyDecision(
                allowsUploads: false,
                pauseReason: "Waiting for charger"
            )
        }
        if minimumBatteryPercent > 0, !status.isCharging,
           let percent = status.batteryPercent, percent < minimumBatteryPercent {
            return PowerPolicyDecision(
                allowsUploads: false,
                pauseReason: "Waiting for battery to reach \(minimumBatteryPercent)%"
            )
        }
        return .allowed
    }
}

/// Publishes charging and battery-level transitions without owning backup policy.
@MainActor
final class PowerPolicyMonitor: ObservableObject {
    @Published private(set) var status: PowerStatus = PowerStatus(isCharging: true, batteryPercent: nil)
    var onStatusChange: ((PowerStatus) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        status = PowerStatus.current()
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                            object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                            object: nil, queue: .main, using: handler))
    }

    private func refresh() {
        let next = PowerStatus.current()
        guard status != next else { return }
        status = next
        onStatusChange?(next)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
