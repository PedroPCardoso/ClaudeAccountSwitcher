import Foundation
import CryptoKit

public struct ClaudeQuota: Codable, Equatable, Sendable {
    public let key: String
    public let usedPercent: Double
    public let resetAt: Date?

    public init(key: String, usedPercent: Double, resetAt: Date? = nil) {
        self.key = key; self.usedPercent = usedPercent; self.resetAt = resetAt
    }
}

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let plan: String?
    public let quotas: [ClaudeQuota]
    public let source: String

    public init(fetchedAt: Date = .now, plan: String? = nil, quotas: [ClaudeQuota], source: String) {
        self.fetchedAt = fetchedAt; self.plan = plan; self.quotas = quotas; self.source = source
    }
}

public enum ClaudeUsageError: Error { case tokenUnavailable, invalidResponse, unauthorized }

/// Reads the same OAuth usage endpoint used by 9router. The endpoint is a
/// consumer endpoint (not the public Anthropic API) and may change upstream.
public struct ClaudeUsageService: Sendable {
    public init() {}

    public func fetch(profileDirectory: URL) async throws -> ClaudeUsageSnapshot {
        guard let token = accessToken(profileDirectory: profileDirectory) else { throw ClaudeUsageError.tokenUnavailable }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.invalidResponse }
        guard http.statusCode != 401 && http.statusCode != 403 else { throw ClaudeUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ClaudeUsageError.invalidResponse }
        return try parse(data: data)
    }

    private func parse(data: Data) throws -> ClaudeUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeUsageError.invalidResponse }
        var quotas: [ClaudeQuota] = []
        let iso = ISO8601DateFormatter()
        if let five = root["five_hour"] as? [String: Any], let value = five["utilization"] as? NSNumber {
            quotas.append(ClaudeQuota(key: "Janela 5h", usedPercent: value.doubleValue, resetAt: (five["resets_at"] as? String).flatMap(iso.date)))
        }
        if let seven = root["seven_day"] as? [String: Any], let value = seven["utilization"] as? NSNumber {
            quotas.append(ClaudeQuota(key: "Semanal", usedPercent: value.doubleValue, resetAt: (seven["resets_at"] as? String).flatMap(iso.date)))
        }
        for (key, raw) in root where key.hasPrefix("seven_day_") {
            guard let window = raw as? [String: Any], let value = window["utilization"] as? NSNumber else { continue }
            let model = key.replacingOccurrences(of: "seven_day_", with: "").capitalized
            quotas.append(ClaudeQuota(key: "Semanal \(model)", usedPercent: value.doubleValue, resetAt: (window["resets_at"] as? String).flatMap(iso.date)))
        }
        guard !quotas.isEmpty else { throw ClaudeUsageError.invalidResponse }
        return ClaudeUsageSnapshot(plan: root["plan"] as? String ?? "Claude Pro/Max", quotas: quotas, source: "Anthropic OAuth (Claude Code)")
    }

    private func accessToken(profileDirectory: URL) -> String? {
        let digest = SHA256.hash(data: Data(profileDirectory.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let service = "Claude Code-credentials-\(suffix)"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try? process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let token = root["accessToken"] as? String { return token }
        if let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String { return token }
        return nil
    }
}
