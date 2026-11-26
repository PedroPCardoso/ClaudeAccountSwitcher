import Foundation

/// Onde um `.jsonl` de sessão vive dentro do diretório de config de um perfil.
/// - `projects/<slug>/<sessão>.jsonl` → sessão principal (`parentSessionID == nil`);
/// - `projects/<slug>/<sessão>/subagents/agent-<x>.jsonl` → transcrição de subagente da sessão.
public struct SessionFileLocation: Equatable, Sendable {
    /// Caminho relativo ao diretório do perfil, com `/` (chave estável no banco).
    public let relativePath: String
    public let projectSlug: String
    /// Nome do arquivo sem `.jsonl`.
    public let sessionID: String
    /// Sessão dona, para transcrições de subagente.
    public let parentSessionID: String?

    public init(relativePath: String, projectSlug: String, sessionID: String, parentSessionID: String?) {
        self.relativePath = relativePath; self.projectSlug = projectSlug; self.sessionID = sessionID; self.parentSessionID = parentSessionID
    }

    /// O id que o usuário passa para `claude --resume`.
    public var resumeID: String { parentSessionID ?? sessionID }

    public static func parse(relativePath: String) -> SessionFileLocation? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "projects", let file = parts.last, file.hasSuffix(".jsonl") else { return nil }
        let session = String(file.dropLast(".jsonl".count))
        guard !session.isEmpty else { return nil }
        let parent = parts.count >= 4 ? parts[2] : nil
        return SessionFileLocation(relativePath: relativePath, projectSlug: parts[1], sessionID: session, parentSessionID: parent)
    }
}

/// Dados derivados de uma linha `user`/`assistant` do `.jsonl`, para busca e análise.
public struct SessionMessageRecord: Equatable, Sendable {
    public var uuid: String?
    public var type: String
    public var timestamp: String?
    public var cwd: String?
    public var gitBranch: String?
    public var isSidechain: Bool
    public var model: String?
    public var messageID: String?
    public var requestID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    /// Texto escrito pelo usuário ou pelo assistente (blocos `text`). Saída de ferramentas,
    /// `tool_use` e `thinking` ficam de fora: são o grosso dos bytes e poluiriam a busca.
    public var text: String
}

public enum SessionLineParser {
    /// `nil` para linhas que não são mensagem (`attachment`, `system`, metadados) ou JSON inválido.
    public static func parse(_ line: Data) -> SessionMessageRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant" else { return nil }
        let message = object["message"] as? [String: Any] ?? [:]
        let usage = message["usage"] as? [String: Any]
        var text = ""
        // `isMeta`: lembretes e caveats que o CLI injeta como se fossem do usuário.
        if (object["isMeta"] as? Bool) != true {
            if let content = message["content"] as? String {
                text = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
        }
        func int(_ key: String) -> Int? { (usage?[key] as? NSNumber)?.intValue }
        return SessionMessageRecord(
            uuid: object["uuid"] as? String,
            type: type,
            timestamp: object["timestamp"] as? String,
            cwd: object["cwd"] as? String,
            gitBranch: object["gitBranch"] as? String,
            isSidechain: (object["isSidechain"] as? Bool) ?? false,
            model: message["model"] as? String,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheReadTokens: int("cache_read_input_tokens"),
            cacheCreationTokens: int("cache_creation_input_tokens"),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum SessionSearchQuery {
    /// Converte o texto digitado numa expressão FTS5 segura: cada palavra vira um termo entre
    /// aspas (todas obrigatórias), então `-`, `:`, `*` e aspas não viram sintaxe do FTS.
    /// Retorna `nil` se não sobrar nenhuma palavra.
    public static func ftsExpression(_ input: String) -> String? {
        let terms = input.split(whereSeparator: { $0.isWhitespace }).map { term in
            "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}

/// Preferência e cadência da cópia de sessões feita pelo app.
public enum SessionArchiveSettings {
    public static let defaultsKey = "sessionArchiveEnabled"
    /// De 5 em 5 minutos.
    public static let interval: TimeInterval = 300

    /// Ligado por padrão (chave ausente = ligado).
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}
