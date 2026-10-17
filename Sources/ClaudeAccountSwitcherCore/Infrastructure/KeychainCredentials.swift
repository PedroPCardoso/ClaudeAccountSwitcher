import Foundation
import CryptoKit

/// Credenciais OAuth que o Claude Code guarda no Keychain, uma por `CLAUDE_CONFIG_DIR`:
/// serviço `Claude Code-credentials-<8 hex de sha256(dir)>`, conta = usuário do macOS.
/// `remove()` do store apaga o diretório mas não esse item; sem isto o token ficava para sempre.
public struct KeychainCredentials: Sendable {
    public static let servicePrefix = "Claude Code-credentials-"
    public init() {}

    public static func serviceName(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        return servicePrefix + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Extrai os serviços `Claude Code-credentials-*` de um `security dump-keychain`
    /// (só atributos, nunca segredos).
    public static func parseServices(dump: String) -> [String] {
        var found = Set<String>()
        for line in dump.split(separator: "\n") where line.contains("\"svce\"") {
            guard let start = line.range(of: "=\""), let end = line.range(of: "\"", range: start.upperBound..<line.endIndex) else { continue }
            let service = String(line[start.upperBound..<end.lowerBound])
            if service.hasPrefix(servicePrefix) { found.insert(service) }
        }
        return found.sorted()
    }

    /// Serviços presentes que não pertencem a nenhum diretório conhecido (perfis já removidos).
    public static func stale(services: [String], knownDirectories: [URL]) -> [String] {
        let known = Set(knownDirectories.map(serviceName(for:)))
        return services.filter { !known.contains($0) }
    }

    public func listServices() -> [String] {
        guard let result = try? ProcessRunner(outputLimit: 8 * 1024 * 1024).run(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: ["dump-keychain"], timeout: 30) else { return [] }
        return Self.parseServices(dump: result.stdout)
    }

    /// Apaga o item de um serviço. Devolve `false` quando não existia (exit 44 do `security`).
    @discardableResult
    public func delete(service: String) throws -> Bool {
        do {
            _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: ["delete-generic-password", "-s", service, "-a", NSUserName()], timeout: 15)
            return true
        } catch ProcessRunnerError.failed(let result) where result.exitCode == 44 {
            return false
        }
    }

    @discardableResult
    public func delete(for directory: URL) throws -> Bool { try delete(service: Self.serviceName(for: directory)) }
}
