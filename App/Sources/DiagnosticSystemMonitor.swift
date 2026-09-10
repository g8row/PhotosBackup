import Foundation
import os
import UIKit

/// Process facts a report needs to explain a termination or a slow window.
enum DiagnosticProcessInfo {
    /// Physical footprint: the number iOS compares against the app's memory
    /// limit before terminating it.
    static func memoryFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    /// How much more the app may allocate before iOS terminates it. Zero on the
    /// Simulator, which has no per-app limit, so that reads as unknown.
    static func availableMemory() -> Int64? {
        let value = os_proc_available_memory()
        return value > 0 ? Int64(value) : nil
    }

    static func memoryDescription() -> String {
        "memory in use \(bytes(memoryFootprint())), available \(bytes(availableMemory()))"
    }

    static func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
    }

    @MainActor
    static func batteryDescription() -> String {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel >= 0 ? "\(Int((device.batteryLevel * 100).rounded()))%" : "level unknown"
        switch device.batteryState {
        case .charging: return "battery \(level), charging"
        case .full: return "battery full, on power"
        case .unplugged: return "battery \(level), not charging"
        case .unknown: return "battery \(level)"
        @unknown default: return "battery \(level)"
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func backgroundRefresh(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "on"
        case .denied: return "off"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}

/// Remembers what the process was last doing, so the next launch can tell an
/// ordinary iOS termination from one that happened while the app was working.
///
/// iOS terminates suspended apps silently all the time. That is not a fault
/// and is not reported. A process that disappears while the app was open, while
/// it was starting, or during a background window iOS had granted it is what a
/// crash or a memory-limit termination looks like from the inside.
///
/// UserDefaults because each write reaches cfprefsd straight away, so the last
/// phase survives the process dying a moment later.
enum AppSessionTracker {
    enum Phase: String {
        case launching
        case active
        case inactive
        case background
        case backgroundWork

        var isExecuting: Bool { self == .launching || self == .active || self == .backgroundWork }
    }

    static let phaseKey = "diagnostics.session.phase"
    static let phaseDateKey = "diagnostics.session.phaseAt"
    static let versionKey = "diagnostics.session.appVersion"
    static let previousOutcomeKey = "diagnostics.session.previousOutcome"

    /// Call once per launch, before anything notes a phase. Returns what is
    /// worth saying about how the previous session ended, or nil when it ended
    /// the ordinary way. A launch is recorded as `.launching` unless the caller
    /// knows it is a background launch; every background entry point notes its
    /// own phase straight after.
    @discardableResult
    static func beginLaunch(
        inBackground: Bool,
        version: String,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> (message: String, level: DiagnosticEvent.Level)? {
        let previous = defaults.string(forKey: phaseKey).flatMap(Phase.init(rawValue:))
        let previousAt = defaults.double(forKey: phaseDateKey)
        let previousVersion = defaults.string(forKey: versionKey)
        let when = previousAt > 0
            ? " (last seen \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: previousAt))))"
            : ""

        var outcome: (message: String, level: DiagnosticEvent.Level)?
        if let previousVersion, previousVersion != version {
            // Installing an update ends the old process however it was running.
            outcome = ("Updated from \(previousVersion) to \(version)", .info)
        } else if let previous, previous.isExecuting {
            let during: String
            switch previous {
            case .launching: during = "while it was starting"
            case .backgroundWork: during = "during a background run iOS had granted"
            default: during = "while it was open"
            }
            outcome = ("The previous session ended unexpectedly \(during)\(when). This is how a crash or an iOS memory-limit termination looks; iOS's own crash report, if shared, appears under Crash Reports.", .error)
        } else if previous == .inactive {
            outcome = ("The previous session ended while the app switcher was showing\(when) — usually the app was swiped away, which also stops background uploads until the app is opened again.", .info)
        }

        if let outcome, outcome.level != .info {
            defaults.set(outcome.message, forKey: previousOutcomeKey)
        } else {
            defaults.removeObject(forKey: previousOutcomeKey)
        }
        defaults.set(version, forKey: versionKey)
        note(inBackground ? .background : .launching, defaults: defaults, now: now)
        return outcome
    }

    static func note(_ phase: Phase, defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(phase.rawValue, forKey: phaseKey)
        defaults.set(now.timeIntervalSince1970, forKey: phaseDateKey)
    }

    /// The unexpected ending detected at this launch, for the report.
    static func previousSessionOutcome(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: previousOutcomeKey)
    }
}

/// Records the system conditions that change what iOS lets the app do: memory
/// pressure, Low Power Mode, heat, and the Background App Refresh switch.
@MainActor
final class DiagnosticSystemObserver {
    static let shared = DiagnosticSystemObserver()
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            DiagnosticEventLog.shared.record(
                "system",
                "iOS sent a memory warning; \(DiagnosticProcessInfo.memoryDescription())",
                level: .warning
            )
        })
        tokens.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            DiagnosticEventLog.shared.record(
                "system",
                on ? "Low Power Mode turned on; iOS runs fewer and shorter background tasks"
                   : "Low Power Mode turned off",
                level: on ? .warning : .info
            )
        })
        tokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            let state = ProcessInfo.processInfo.thermalState
            let hot = state == .serious || state == .critical
            DiagnosticEventLog.shared.record(
                "system",
                "Thermal state is \(DiagnosticProcessInfo.thermal(state))" + (hot ? "; iOS may defer or stop background work" : ""),
                level: hot ? .warning : .info
            )
        })
        tokens.append(center.addObserver(
            forName: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let status = UIApplication.shared.backgroundRefreshStatus
                DiagnosticEventLog.shared.record(
                    "system",
                    "Background App Refresh is now \(DiagnosticProcessInfo.backgroundRefresh(status))"
                        + (status == .available ? "" : "; iOS will not start background backups"),
                    level: status == .available ? .info : .warning
                )
            }
        })
    }
}
