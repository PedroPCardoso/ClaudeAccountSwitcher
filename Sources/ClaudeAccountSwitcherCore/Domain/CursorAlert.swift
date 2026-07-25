import Foundation

/// Tracks whether the Cursor budget alert has already fired for the current
/// billing cycle (`billingCycleEnd`), so each cycle alerts at most once when
/// `usedPercent` crosses the configured threshold.
public struct CursorBudgetAlertTracker: Sendable {
    private var alertedCycleEnd: Date?

    public init() {}

    /// Returns `true` exactly when `usedPercent` newly crosses `threshold` for
    /// this `billingCycleEnd`. A new cycle (different end date) rearms.
    @discardableResult
    public mutating func evaluate(usedPercent: Double, threshold: Double, billingCycleEnd: Date?) -> Bool {
        guard let billingCycleEnd else { return false }
        if alertedCycleEnd != billingCycleEnd {
            alertedCycleEnd = nil
        }
        guard usedPercent >= threshold else { return false }
        guard alertedCycleEnd != billingCycleEnd else { return false }
        alertedCycleEnd = billingCycleEnd
        return true
    }

    public mutating func reset() { alertedCycleEnd = nil }
}

public enum CursorBudgetAlertThreshold {
    public static let defaultsKey = "cursorBudgetAlertThreshold"
    public static let `default`: Double = 80

    public static func resolve(_ raw: Double) -> Double {
        (raw > 0 && raw <= 100) ? raw : `default`
    }
}

/// Preference key that enables/disables Cursor usage monitoring entirely.
public enum CursorMonitoring {
    public static let defaultsKey = "cursorMonitoringEnabled"
    /// Default on: if the key was never written, monitoring is enabled.
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) == nil { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}
