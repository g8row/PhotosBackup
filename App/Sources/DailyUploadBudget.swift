import Foundation

struct DailyUploadBudgetDecision: Equatable, Sendable {
    let allowsUploads: Bool
    let pauseReason: String?

    static let allowed = DailyUploadBudgetDecision(allowsUploads: true, pauseReason: nil)
}

/// Pure policy and formatting helpers for the daily upload data limit (issue #14).
enum DailyUploadBudget {
    /// Choices shown in Settings (`0` disables the daily limit).
    /// Values use decimal SI bytes to match `ByteCountFormatter`'s `.file` display.
    static let limitChoices: [Int64] = [
        0,
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
        10_000_000_000,
    ]

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func label(for limitBytes: Int64) -> String {
        limitBytes <= 0 ? "Off" : formatBytes(limitBytes)
    }

    /// Local calendar day identifier (`yyyy-MM-dd`) for resetting the daily counter.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func decision(limitBytes: Int64, usedTodayBytes: Int64) -> DailyUploadBudgetDecision {
        guard limitBytes > 0, usedTodayBytes >= limitBytes else { return .allowed }
        return DailyUploadBudgetDecision(
            allowsUploads: false,
            pauseReason: "Daily upload limit reached (\(formatBytes(limitBytes))). Resumes tomorrow."
        )
    }
}

/// Tracks bytes actually uploaded on the current local calendar day.
/// Deduplicated items (`alreadyBackedUp`) do not upload file bytes and are not counted.
@MainActor
final class DailyUploadTracker: ObservableObject {
    private enum Key {
        static let bytes = "backup.dailyUploadedBytes"
        static let day = "backup.dailyUploadedDay"
    }

    @Published private(set) var usedTodayBytes: Int64
    private var trackedDay: String
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: Date = Date()) {
        self.defaults = defaults
        self.calendar = calendar
        let today = DailyUploadBudget.dayKey(for: now, calendar: calendar)
        if defaults.string(forKey: Key.day) == today {
            trackedDay = today
            usedTodayBytes = max(0, Int64(defaults.integer(forKey: Key.bytes)))
            // Prefer Int64 storage when present (handles > 2 GB on 32-bit or large values cleanly).
            if let stored = defaults.object(forKey: Key.bytes) as? Int64 {
                usedTodayBytes = max(0, stored)
            } else if let stored = defaults.object(forKey: Key.bytes) as? NSNumber {
                usedTodayBytes = max(0, stored.int64Value)
            }
        } else {
            trackedDay = today
            usedTodayBytes = 0
            defaults.set(today, forKey: Key.day)
            defaults.set(Int64(0), forKey: Key.bytes)
        }
    }

    func refreshDay(now: Date = Date()) {
        let today = DailyUploadBudget.dayKey(for: now, calendar: calendar)
        guard today != trackedDay else { return }
        trackedDay = today
        usedTodayBytes = 0
        defaults.set(today, forKey: Key.day)
        defaults.set(Int64(0), forKey: Key.bytes)
    }

    func recordUploaded(bytes: Int64, now: Date = Date()) {
        refreshDay(now: now)
        guard bytes > 0 else { return }
        usedTodayBytes += bytes
        defaults.set(trackedDay, forKey: Key.day)
        defaults.set(usedTodayBytes, forKey: Key.bytes)
    }

    func resetToday(now: Date = Date()) {
        trackedDay = DailyUploadBudget.dayKey(for: now, calendar: calendar)
        usedTodayBytes = 0
        defaults.set(trackedDay, forKey: Key.day)
        defaults.set(Int64(0), forKey: Key.bytes)
    }
}
