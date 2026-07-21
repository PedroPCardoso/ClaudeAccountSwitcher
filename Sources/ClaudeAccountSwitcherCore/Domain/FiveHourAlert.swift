import Foundation

/// Tracks whether the active account has already fired a 5-hour usage alert
/// for the current crossing of the configured threshold, so the alert fires
/// once per crossing instead of on every usage refresh.
public struct FiveHourAlertTracker: Sendable {
    public private(set) var alerted = false

    public init() {}

    /// Returns `true` exactly when `usedPercent` newly crosses `threshold`.
    @discardableResult
    public mutating func evaluate(usedPercent: Double, threshold: Double) -> Bool {
        guard usedPercent >= threshold else { alerted = false; return false }
        guard !alerted else { return false }
        alerted = true
        return true
    }

    public mutating func reset() { alerted = false }
}

public enum FiveHourAlertThreshold {
    public static let defaultsKey = "fiveHourAlertThreshold"
    public static let `default`: Double = 80

    public static func resolve(_ raw: Double) -> Double {
        (raw > 0 && raw <= 100) ? raw : `default`
    }
}

public enum FiveHourAlertSound: String, CaseIterable, Sendable {
    case none, standard, basso, glass, hero, ping, sosumi

    public static let defaultsKey = "fiveHourAlertSoundName"
    public static let `default`: FiveHourAlertSound = .standard

    public init(defaultsValue: String?) {
        self = defaultsValue.flatMap(FiveHourAlertSound.init(rawValue:)) ?? .standard
    }
}

/// Tracks, per profile, which `resetAt` of the weekly window has already
/// fired a "credits available" alert, so each renewal alerts at most once.
public struct WeeklyCreditsAlertTracker: Sendable {
    private var alertedResetAt: [UUID: Date] = [:]

    public init() {}

    @discardableResult
    public mutating func evaluate(profileID: UUID, usedPercent: Double, resetAt: Date?, availableThreshold: Double, now: Date = .now) -> Bool {
        guard let resetAt else { return false }
        let hoursUntilReset = resetAt.timeIntervalSince(now) / 3600
        guard hoursUntilReset > 0, hoursUntilReset <= 24 else {
            alertedResetAt[profileID] = nil
            return false
        }
        guard (100 - usedPercent) >= availableThreshold else { return false }
        guard alertedResetAt[profileID] != resetAt else { return false }
        alertedResetAt[profileID] = resetAt
        return true
    }
}

public enum WeeklyCreditsAlertThreshold {
    public static let defaultsKey = "weeklyCreditsAlertThreshold"
    public static let `default`: Double = 30

    public static func resolve(_ raw: Double) -> Double {
        (raw > 0 && raw <= 100) ? raw : `default`
    }
}
