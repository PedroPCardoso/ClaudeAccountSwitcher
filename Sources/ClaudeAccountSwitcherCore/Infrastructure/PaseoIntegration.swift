import Foundation

public enum PaseoIntegrationError: Error { case configNotFound, invalidConfig }

/// Paseo's daemon resolves `CLAUDE_CONFIG_DIR` from its own `process.env` at spawn time, which
/// it captured once when the daemon started — it never re-reads `launchctl setenv`, so a plain
/// account switch never reaches sessions Paseo opens. To fix that without forcing a daemon
/// restart on every switch, we keep a stable symlink that always points at the active profile's
/// config directory, and point Paseo's `claude` provider at that symlink once. From then on,
/// switching accounts just re-targets the symlink; Paseo resolves it fresh on every new spawn.
public struct PaseoIntegration: Sendable {
    public let appSupport: URL
    public let configURL: URL

    public init(appSupport: URL, paseoHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo", isDirectory: true)) {
        self.appSupport = appSupport
        self.configURL = paseoHome.appendingPathComponent("config.json")
    }

    public var activeConfigDirSymlink: URL { appSupport.appendingPathComponent("active-config-dir") }

    public func isDetected() -> Bool { FileManager.default.fileExists(atPath: configURL.path) }

    /// Atomically re-targets the stable symlink at the given profile directory. Safe to call on
    /// every activation regardless of whether the Paseo integration has been set up.
    public func updateSymlink(to profileDirectory: URL) throws {
        let link = activeConfigDirSymlink
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = appSupport.appendingPathComponent(".active-config-dir.tmp-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: profileDirectory)
        guard rename(tmp.path, link.path) == 0 else { throw ActivationError.missingDirectory }
    }

    public func isConfigured() -> Bool {
        guard let claudeEnv = readClaudeProviderEnv() else { return false }
        return claudeEnv["CLAUDE_CONFIG_DIR"] as? String == activeConfigDirSymlink.path
    }

    /// Points Paseo's built-in `claude` provider at the stable symlink, preserving every other
    /// field in `config.json` (including any custom providers like a manually configured
    /// `claude-work`). Backs up the original file first. The daemon still needs a one-time
    /// `paseo daemon restart` to pick up this change; later account switches do not.
    @discardableResult
    public func integrate() throws -> URL {
        guard let raw = try? Data(contentsOf: configURL) else { throw PaseoIntegrationError.configNotFound }
        guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw PaseoIntegrationError.invalidConfig }

        let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL = backups.appendingPathComponent("paseo-config-\(Int(Date().timeIntervalSince1970)).json")
        try raw.write(to: backupURL, options: .atomic)

        var agents = root["agents"] as? [String: Any] ?? [:]
        var providers = agents["providers"] as? [String: Any] ?? [:]
        var claude = providers["claude"] as? [String: Any] ?? [:]
        var env = claude["env"] as? [String: Any] ?? [:]
        env["CLAUDE_CONFIG_DIR"] = activeConfigDirSymlink.path
        claude["env"] = env
        providers["claude"] = claude
        agents["providers"] = providers
        root["agents"] = agents

        // Sem `.sortedKeys`: reordenar tudo alfabeticamente produzia diffs enormes no
        // config.json do usuário a cada integração. Só alteramos o campo do provider claude.
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: configURL, options: .atomic)
        return backupURL
    }

    private func readClaudeProviderEnv() -> [String: Any]? {
        guard let raw = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let agents = root["agents"] as? [String: Any],
              let providers = agents["providers"] as? [String: Any],
              let claude = providers["claude"] as? [String: Any],
              let env = claude["env"] as? [String: Any] else { return nil }
        return env
    }
}
