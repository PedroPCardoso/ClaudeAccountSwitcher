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
