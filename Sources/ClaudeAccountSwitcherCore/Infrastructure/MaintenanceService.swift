import Foundation

public struct MaintenanceReport: Equatable, Sendable {
    public var shellBackups: [URL] = []
    public var claudeTempFiles: [URL] = []
    public var orphanedDirectories: [URL] = []
    public var staleKeychainServices: [String] = []
    public var isEmpty: Bool { shellBackups.isEmpty && claudeTempFiles.isEmpty && orphanedDirectories.isEmpty && staleKeychainServices.isEmpty }
    public init() {}
}

/// Limpeza de resíduos que o uso normal acumula e nada apagava: backups de dotfiles a cada
/// reparo da integração (`Backups/shell-*`), `.claude.json.tmp.*` que o CLI deixa quando é
/// interrompido entre write e rename, diretórios de perfil órfãos e itens de Keychain de perfis
/// removidos. `scan` só lista; `apply` apaga exatamente o que foi listado.
public struct MaintenanceService: Sendable {
    public let store: ProfileStore
    public let appSupport: URL
    public let keychain: KeychainCredentials?
    public init(store: ProfileStore, appSupport: URL, keychain: KeychainCredentials? = nil) { self.store = store; self.appSupport = appSupport; self.keychain = keychain }

    public func scan(now: Date = .now, keepShellBackupsPerFile: Int = 5, tempFilesOlderThan: TimeInterval = 7 * 24 * 3600) throws -> MaintenanceReport {
        var report = MaintenanceReport()
        let fm = FileManager.default
        // Backups de shell: `shell-<epoch>-<arquivo>`; mantém os N mais novos de cada arquivo.
        let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var groups: [String: [(stamp: Int, url: URL)]] = [:]
            for url in entries where url.lastPathComponent.hasPrefix("shell-") {
                let rest = url.lastPathComponent.dropFirst("shell-".count)
                guard let dash = rest.firstIndex(of: "-"), let stamp = Int(rest[..<dash]) else { continue }
                groups[String(rest[rest.index(after: dash)...]), default: []].append((stamp, url))
            }
            for (_, items) in groups {
                let sorted = items.sorted { $0.stamp > $1.stamp }
                report.shellBackups += sorted.dropFirst(keepShellBackupsPerFile).map(\.url)
            }
        }
        // Temporários do CLI dentro de cada perfil, só os velhos (um recente pode estar em uso).
        let profiles = try store.list()
        for profile in profiles {
            guard let entries = try? fm.contentsOfDirectory(at: profile.directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { continue }
            for url in entries where url.lastPathComponent.hasPrefix(".claude.json.tmp.") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) > tempFilesOlderThan { report.claudeTempFiles.append(url) }
            }
        }
        report.orphanedDirectories = try store.orphanedProfileDirectories()
        if let keychain {
            report.staleKeychainServices = KeychainCredentials.stale(services: keychain.listServices(), knownDirectories: profiles.map(\.directory))
        }
        report.shellBackups.sort { $0.path < $1.path }; report.claudeTempFiles.sort { $0.path < $1.path }
        return report
    }

    /// Apaga o que o relatório listou. Erros individuais não interrompem o resto; devolve quantos
    /// itens foram de fato removidos.
    @discardableResult
    public func apply(_ report: MaintenanceReport) -> Int {
        var removed = 0
        for url in report.shellBackups + report.claudeTempFiles + report.orphanedDirectories {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if let keychain {
            for service in report.staleKeychainServices where (try? keychain.delete(service: service)) == true { removed += 1 }
        }
        return removed
    }
}
