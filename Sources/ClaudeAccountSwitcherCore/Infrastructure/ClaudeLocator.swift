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
            // Ordena por versão semântica (mais nova primeiro). Ordenar por string faria
            // "v10" < "v9" e escolheria a versão errada do binário.
            candidates.append(contentsOf: entries.sorted { Self.isVersion($0.lastPathComponent, newerThan: $1.lastPathComponent) }.map { $0.appendingPathComponent("claude") })
        }
        candidates.append(home.appendingPathComponent(".local/bin/claude"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            if candidate.path.contains("Claude Account Switcher") { throw ClaudeLocatorError.managedLauncher(candidate) }
            return candidate
        }
        throw ClaudeLocatorError.notFound
    }

    /// Compara nomes de diretório de versão numericamente, componente a componente
    /// (`1.10.0` > `1.9.0`). Cada componente usa apenas o prefixo numérico, então
    /// sufixos como `-beta` não quebram a comparação; empate cai para ordem de string.
    public static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = numericComponents(lhs), b = numericComponents(rhs)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return lhs > rhs
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }
}
