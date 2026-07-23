import Foundation
import CryptoKit

public struct MigrationPlan: Sendable {
    public let sources: [URL]
    public let aliases: [String]
    public let desktopSource: URL?
    public init(sources: [URL], aliases: [String], desktopSource: URL? = nil) { self.sources = sources; self.aliases = aliases; self.desktopSource = desktopSource }
}
public struct MigrationReport: Sendable { public let imported: [URL]; public let aliases: [String] }

public struct MigrationService: Sendable {
    public let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }

    public func preview(home: URL) throws -> MigrationPlan {
        let fm = FileManager.default
        let candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")].filter { fm.fileExists(atPath: $0.path) }
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        let desktopAppData = home.appendingPathComponent("Library/Application Support/Claude")
        let desktopSource = MigrationService.hasRealDesktopSession(at: desktopAppData) ? desktopAppData : nil
        return MigrationPlan(sources: candidates, aliases: zshrc.components(separatedBy: .newlines).filter { $0.contains("alias claude-work=") || $0.contains("alias code-work=") || $0.contains("alias zed-work=") }, desktopSource: desktopSource)
    }

    public static func hasRealDesktopSession(at directory: URL) -> Bool {
        let fm = FileManager.default
        let cookies = directory.appendingPathComponent("Cookies")
        if let attributes = try? fm.attributesOfItem(atPath: cookies.path), let size = attributes[.size] as? Int, size > 0 { return true }
        let localStorage = directory.appendingPathComponent("Local Storage/leveldb")
        if let entries = try? fm.contentsOfDirectory(atPath: localStorage.path), !entries.isEmpty { return true }
        return false
    }

    private static func copyDesktopSessionContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        for entry in entries {
            if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
            try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    /// Copies the default desktop app session into `profile`'s desktop directory, when the profile
    /// has none of its own yet and a real session exists at the default location. Used right after a
    /// new account finishes logging in through the switcher, since the CLI's OAuth token cannot log the
    /// Electron desktop app in by itself. Returns whether a copy happened, so the caller can confirm
    /// with the user that the copied session actually belongs to the account they just logged into.
    public func copyDefaultDesktopSessionIfAvailable(into profile: Profile, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        guard !MigrationService.hasRealDesktopSession(at: profile.desktopDirectory) else { return false }
        let defaultDesktopData = home.appendingPathComponent("Library/Application Support/Claude")
        guard MigrationService.hasRealDesktopSession(at: defaultDesktopData) else { return false }
        try MigrationService.copyDesktopSessionContents(from: defaultDesktopData, to: profile.desktopDirectory)
        return true
    }

    public func execute(_ plan: MigrationPlan, desktopTarget: URL? = nil) throws -> MigrationReport {
        let fm = FileManager.default; var imported: [URL] = []
        for source in plan.sources {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for entry in entries {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            try store.save(Profile(id: id, name: source.lastPathComponent == ".claude" ? "Claude pessoal" : "Claude work", kind: .custom, directory: destination, health: .unknown))
            imported.append(destination)
            if let desktopSource = plan.desktopSource, source.path == desktopTarget?.path {
                let desktopDestination = destination.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)
                try fm.createDirectory(at: desktopDestination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let desktopEntries = try fm.contentsOfDirectory(at: desktopSource, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
                for entry in desktopEntries {
                    if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                    try fm.copyItem(at: entry, to: desktopDestination.appendingPathComponent(entry.lastPathComponent))
                }
            }
        }
        return MigrationReport(imported: imported, aliases: plan.aliases)
    }

    public func cleanupRecognizedAliases(home: URL, confirmed: Bool) throws {
        guard confirmed else { return }
        let file = home.appendingPathComponent(".zshrc")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !(line.contains("alias claude-work=") || line.contains("alias code-work=") || line.contains("alias zed-work="))
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file, options: .atomic)
    }
}
