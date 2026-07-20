import Foundation

public enum ClaudeLocatorError: Error { case notFound, managedLauncher(URL) }

public struct ClaudeLocator: Sendable {
    public let home: URL
    public let explicitPath: URL?
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, explicitPath: URL? = nil) { self.home = home; self.explicitPath = explicitPath }

    public func locate() throws -> URL {
        var candidates: [URL] = []
        if let explicitPath { candidates.append(explicitPath) }
        let versions = home.appendingPathComponent(".local/share/claude/versions", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: entries.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("claude") })
        }
        candidates.append(home.appendingPathComponent(".local/bin/claude"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            if candidate.path.contains("Claude Account Switcher") { throw ClaudeLocatorError.managedLauncher(candidate) }
            return candidate
        }
        throw ClaudeLocatorError.notFound
    }
}
