import Foundation
import CryptoKit

public struct MigrationPlan: Sendable {
    public let sources: [URL]
    public let aliases: [String]
    public let desktopSource: URL?
    /// `~/.claude.json` global. Sem `CLAUDE_CONFIG_DIR` o Claude Code guarda esse arquivo FORA de
    /// `~/.claude` (MCP servers de usuário, projetos confiáveis, onboarding, conta OAuth). Dentro
    /// de um perfil ele passa a ler `<perfil>/.claude.json`; importar só a pasta perderia tudo isso.
    public let globalConfig: URL?
    public init(sources: [URL], aliases: [String], desktopSource: URL? = nil, globalConfig: URL? = nil) { self.sources = sources; self.aliases = aliases; self.desktopSource = desktopSource; self.globalConfig = globalConfig }
}
public struct MigrationReport: Sendable { public let imported: [URL]; public let aliases: [String] }
public enum MigrationError: Error, Equatable { case desktopAppRunning, symlinkNotImported(URL), notADirectory(URL) }

public struct MigrationService: Sendable {
    public let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }

    public func preview(home: URL) throws -> MigrationPlan {
        let fm = FileManager.default
        let candidates = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude-work")].filter { fm.fileExists(atPath: $0.path) }
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        let desktopAppData = home.appendingPathComponent("Library/Application Support/Claude")
        let desktopSource = MigrationService.hasRealDesktopSession(at: desktopAppData) ? desktopAppData : nil
        let globalConfig = home.appendingPathComponent(".claude.json")
        return MigrationPlan(sources: candidates, aliases: zshrc.components(separatedBy: .newlines).filter { $0.contains("alias claude-work=") || $0.contains("alias code-work=") || $0.contains("alias zed-work=") }, desktopSource: desktopSource, globalConfig: fm.fileExists(atPath: globalConfig.path) ? globalConfig : nil)
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
    ///
    /// Recusa copiar com o app aberto (`isDesktopRunning`): LevelDB/SQLite em escrita produzem uma
    /// cópia inconsistente. A cópia é feita num diretório irmão temporário e renomeada no fim,
    /// para uma cópia interrompida nunca passar por sessão válida em `hasRealDesktopSession`.
    public func copyDefaultDesktopSessionIfAvailable(into profile: Profile, home: URL = FileManager.default.homeDirectoryForCurrentUser, isDesktopRunning: () -> Bool = { false }) throws -> Bool {
        guard !MigrationService.hasRealDesktopSession(at: profile.desktopDirectory) else { return false }
        let defaultDesktopData = home.appendingPathComponent("Library/Application Support/Claude")
        guard MigrationService.hasRealDesktopSession(at: defaultDesktopData) else { return false }
        guard !isDesktopRunning() else { throw MigrationError.desktopAppRunning }
        let fm = FileManager.default
        let destination = profile.desktopDirectory
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".desktop.tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try MigrationService.copyDesktopSessionContents(from: defaultDesktopData, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }   // só um `desktop` vazio/sem sessão chega aqui
        try fm.moveItem(at: staging, to: destination)
        return true
    }

    /// Importa uma pasta de configuração escolhida pelo usuário como perfil novo. Mesmas regras da
    /// migração automática: sem symlinks, e se a pasta for a `~/.claude` padrão traz também o
    /// `~/.claude.json` global (que vive fora dela).
    public func importDirectory(_ source: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, name: String? = nil) throws -> Profile {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw MigrationError.notADirectory(source) }
        let id = UUID(); let destination = try store.createManagedDirectory(id: id)
        do {
            for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw MigrationError.symlinkNotImported(entry) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            let ownConfig = destination.appendingPathComponent(".claude.json")
            let globalConfig = home.appendingPathComponent(".claude.json")
            if source.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path, !fm.fileExists(atPath: ownConfig.path), fm.fileExists(atPath: globalConfig.path) {
                try fm.copyItem(at: globalConfig, to: ownConfig)
            }
        } catch {
            // Não deixa um diretório gerenciado órfão para trás se a cópia falhar no meio.
            try? fm.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        let profile = Profile(id: id, name: name ?? source.lastPathComponent, kind: .custom, directory: destination, health: .unknown)
        try store.save(profile)
        return profile
    }

    public func execute(_ plan: MigrationPlan, desktopTarget: URL? = nil, isDesktopRunning: () -> Bool = { false }) throws -> MigrationReport {
        let fm = FileManager.default; var imported: [URL] = []
        // Decide antes de tocar no disco: copiar LevelDB/SQLite do app aberto gera sessão inconsistente.
        if desktopTarget != nil, plan.desktopSource != nil, isDesktopRunning() { throw MigrationError.desktopAppRunning }
        for source in plan.sources {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for entry in entries {
                if (try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "ClaudeAccountSwitcher", code: 1001, userInfo: [NSLocalizedDescriptionKey: "symbolic links are not imported"]) }
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            // Só a pasta padrão `~/.claude` depende do `~/.claude.json` global; uma pasta usada via
            // CLAUDE_CONFIG_DIR (ex.: ~/.claude-work) já traz o seu próprio e esse vence.
            let ownConfig = destination.appendingPathComponent(".claude.json")
            if source.lastPathComponent == ".claude", let globalConfig = plan.globalConfig, !fm.fileExists(atPath: ownConfig.path), fm.fileExists(atPath: globalConfig.path) {
                try fm.copyItem(at: globalConfig, to: ownConfig)
            }
            try store.save(Profile(id: id, name: source.lastPathComponent == ".claude" ? "Claude pessoal" : "Claude work", kind: .custom, directory: destination, health: .unknown))
            imported.append(destination)
            if let desktopSource = plan.desktopSource, source.path == desktopTarget?.path {
                // Mesmo staging atômico de `copyDefaultDesktopSessionIfAvailable`: uma cópia interrompida
                // nunca passa por sessão válida em `hasRealDesktopSession`.
                let desktopDestination = destination.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true)
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".desktop.tmp-\(UUID().uuidString)", isDirectory: true)
                do { try MigrationService.copyDesktopSessionContents(from: desktopSource, to: staging) }
                catch { try? fm.removeItem(at: staging); throw error }
                try fm.moveItem(at: staging, to: desktopDestination)
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
        let updated = lines.joined(separator: "\n")
        guard updated != content else { return }   // nada a remover: não reescreve nem gera backup
        // Faz backup antes de reescrever o .zshrc do usuário, consistente com o resto do app
        // (ShellIntegrationManager e PaseoIntegration também guardam o original em Backups/).
        try backupZshrc(file)
        try updated.data(using: .utf8)!.write(to: file, options: .atomic)
    }

    private func backupZshrc(_ file: URL) throws {
        let backups = store.root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = backups.appendingPathComponent("zshrc-\(Int(Date().timeIntervalSince1970)).bak")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
    }
}
