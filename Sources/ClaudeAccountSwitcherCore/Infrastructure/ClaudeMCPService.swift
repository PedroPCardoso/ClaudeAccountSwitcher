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
    public func login(profileDirectory: URL, serverName: String) throws {
        do {
            _ = try runner.run(executable: locator.locate(), arguments: ["mcp", "login", serverName],
                               environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path],
                               cwd: workingDirectory, timeout: 300)
        } catch let ProcessRunnerError.failed(result) {
            throw ClaudeMCPError.loginFailed(name: serverName, message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
