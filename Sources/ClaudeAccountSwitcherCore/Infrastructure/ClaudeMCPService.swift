import Foundation

public enum ClaudeMCPError: Error, LocalizedError {
    case listFailed(String), loginFailed(name: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .listFailed(let message): return "claude mcp list: \(message)"
        case .loginFailed(let name, let message): return "claude mcp login \(name): \(message)"
        }
    }
}

/// Lista e autentica servidores MCP de um perfil via CLI oficial (`claude mcp list|login`),
/// sempre com o `CLAUDE_CONFIG_DIR` do perfil — cada conta guarda seus próprios tokens OAuth.
public struct ClaudeMCPService: Sendable {
    public let locator: ClaudeLocator
    public let runner: ProcessRunner

    public init(locator: ClaudeLocator, runner: ProcessRunner = .init(outputLimit: 256 * 1024)) {
        self.locator = locator; self.runner = runner
    }

    /// Roda na home: servidores de escopo de projeto (`.mcp.json`) dependem do cwd e não
    /// fazem sentido numa ação global da barra de menu.
    private var workingDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    public func list(profileDirectory: URL) throws -> [MCPServerStatus] {
        do {
            // `mcp list` faz health check de cada servidor; 90 s cobre servidores lentos.
            let result = try runner.run(executable: locator.locate(), arguments: ["mcp", "list"],
                                        environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path],
                                        cwd: workingDirectory, timeout: 90)
            return MCPListParser.parse(result.stdout)
        } catch let ProcessRunnerError.failed(result) {
            throw ClaudeMCPError.listFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Abre o navegador para o OAuth do servidor. Conectores claude.ai retornam logo (o fluxo
    /// termina no claude.ai); servidores HTTP/SSE esperam o callback — timeout generoso.
    ///
    /// O CLI recusa `mcp login` de servidores HTTP/SSE sem TTY ("this isn't an interactive
    /// terminal"), e o app de barra de menu não tem um. `/usr/bin/script` fornece um pseudo-TTY
    /// sem abrir janela de terminal; o browser abre e o CLI espera o callback OAuth em localhost.
    public func login(profileDirectory: URL, serverName: String) throws {
        let claude = try locator.locate()
        do {
            _ = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/script"),
                               arguments: ["-q", "/dev/null", claude.path, "mcp", "login", serverName],
                               environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path],
                               cwd: workingDirectory, timeout: 300)
        } catch let ProcessRunnerError.failed(result) {
            throw ClaudeMCPError.loginFailed(name: serverName, message: Self.lastMeaningfulLine(result.stdout + "\n" + result.stderr))
        } catch ProcessRunnerError.timedOut {
            throw ClaudeMCPError.loginFailed(name: serverName, message: "timeout (5 min)")
        }
    }

    /// Saída de pty vem com códigos ANSI/OSC-8 e a URL de autorização (com `state`/PKCE):
    /// devolve só a última linha legível que não seja URL, para a mensagem de erro.
    public static func lastMeaningfulLine(_ output: String) -> String {
        let cleaned = output
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        let lines = cleaned.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("://") }
        return lines.last ?? "falhou"
    }
}
