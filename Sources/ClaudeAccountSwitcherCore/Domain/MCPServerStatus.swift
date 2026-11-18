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

    /// Só servidores HTTP/SSE e conectores claude.ai aceitam `claude mcp login`.
    public var needsAuthentication: Bool { state == .needsAuthentication }
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
