import Foundation

/// Estado de um servidor MCP como reportado por `claude mcp list`.
public enum MCPServerState: Sendable, Equatable {
    case connected, needsAuthentication, failed, pendingApproval, unknown
}

public struct MCPServerStatus: Sendable, Equatable {
    public let name: String
    public let target: String
    public let state: MCPServerState

    public init(name: String, target: String, state: MCPServerState) {
        self.name = name; self.target = target; self.state = state
    }

    public var needsAuthentication: Bool { state == .needsAuthentication }

    /// Só servidores remotos (HTTP/SSE, conectores claude.ai) aceitam `claude mcp login`;
    /// stdio (`npx …`) não tem OAuth.
    public var supportsLogin: Bool { target.hasPrefix("https://") || target.hasPrefix("http://") }

    /// Conectores do claude.ai são geridos em claude.ai/settings; só entram na lista quando pedem login.
    public var isClaudeAIConnector: Bool { name.hasPrefix("claude.ai ") }
}

/// Quais servidores oferecer na ação "Autenticar MCPs" e quais já vêm marcados.
public enum MCPAuthCandidates {
    public struct Candidate: Sendable, Equatable {
        public let server: MCPServerStatus
        public let preselected: Bool
    }

    /// Todos que pedem login (marcados) + servidores HTTP/SSE próprios já conectados ou com
    /// falha (desmarcados — para renovar um token que vive expirando, ex.: MCPs internos).
    /// Conectores claude.ai conectados ficam de fora (dezenas, geridos no claude.ai).
    public static func select(_ servers: [MCPServerStatus]) -> [Candidate] {
        let pending = servers.filter(\.needsAuthentication).map { Candidate(server: $0, preselected: true) }
        let renewable = servers
            .filter { !$0.needsAuthentication && $0.supportsLogin && !$0.isClaudeAIConnector && $0.state != .pendingApproval }
            .map { Candidate(server: $0, preselected: false) }
        return pending + renewable
    }
}

/// Parser puro da saída textual de `claude mcp list`. Formato de cada linha:
/// `<nome>: <comando ou url> - <marcador> <descrição>` (marcadores ✔ ! ✘ ⏸).
/// Linhas fora do formato (cabeçalho "Checking MCP server health…", vazias) são ignoradas.
public enum MCPListParser {
    public static func parse(_ output: String) -> [MCPServerStatus] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> MCPServerStatus? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Nome termina no primeiro ": "; o estado vem depois do ÚLTIMO " - " (URLs e
        // argumentos de comando podem conter " - " raramente, nomes não contêm ": ").
        guard let nameEnd = trimmed.range(of: ": "),
              let stateStart = trimmed.range(of: " - ", options: .backwards),
              nameEnd.upperBound <= stateStart.lowerBound else { return nil }
        let name = String(trimmed[..<nameEnd.lowerBound])
        guard !name.isEmpty else { return nil }
        let target = String(trimmed[nameEnd.upperBound..<stateStart.lowerBound])
        let stateText = trimmed[stateStart.upperBound...].lowercased()
        let state: MCPServerState
        if stateText.hasPrefix("!") || stateText.contains("needs authentication") {
            state = .needsAuthentication
        } else if stateText.hasPrefix("✘") || stateText.contains("failed") {
            state = .failed
        } else if stateText.hasPrefix("⏸") || stateText.contains("pending") {
            state = .pendingApproval
        } else if stateText.hasPrefix("✔") || stateText.contains("connected") {
            state = .connected
        } else {
            state = .unknown
        }
        return MCPServerStatus(name: name, target: target, state: state)
    }
}
