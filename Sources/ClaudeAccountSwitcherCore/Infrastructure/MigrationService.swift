import Foundation
import CryptoKit

public struct MigrationPlan: Sendable { public let sources: [URL]; public let aliases: [String]; public init(sources: [URL], aliases: [String]) { self.sources = sources; self.aliases = aliases } }
public struct MigrationReport: Sendable { public let imported: [URL]; public let backups: [URL]; public let aliases: [String] }

public struct MigrationService: Sendable {
    public let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }
    public func preview(home: URL) throws -> MigrationPlan {
        let fm = FileManager.default
        let candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")].filter { fm.fileExists(atPath: $0.path) }
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        return MigrationPlan(sources: candidates, aliases: zshrc.components(separatedBy: .newlines).filter { $0.contains("alias claude-work=") || $0.contains("alias code-work=") || $0.contains("alias zed-work=") })
    }
    public func execute(_ plan: MigrationPlan) throws -> MigrationReport {
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
        }
        return MigrationReport(imported: imported, backups: [], aliases: plan.aliases)
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
