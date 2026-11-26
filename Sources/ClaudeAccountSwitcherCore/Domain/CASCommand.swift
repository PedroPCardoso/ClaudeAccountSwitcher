import Foundation

/// Comando reconhecido pela CLI `cas`. `help` carrega o código de saída desejado para que o
/// dispatch (uso incorreto → exit ≠ 0; ajuda explícita → exit 0) seja decidido de forma pura,
/// sem chamar `exit()` — o que permite testar o parsing isoladamente.
public enum CASCommand: Equatable, Sendable {
    case list
    case current
    case switchProfile(String)
    /// Copia agora as sessões de todos os perfis para o banco local.
    case sync
    /// Busca de texto completo nas sessões arquivadas.
    case search(String, limit: Int)
    /// Recria no disco uma sessão arquivada (`profile` = perfil de destino, opcional).
    case restore(String, profile: String?)
    /// Abre o banco no `sqlite3` (somente leitura); argumentos extras vão direto para ele.
    case db([String])
    case help(exitCode: Int32)
}

/// Parsing puro dos argumentos da CLI (sem o nome do programa). Comando desconhecido ou uso
/// incorreto resolvem para `.help(exitCode: 1)`; `help`/`--help`/`-h` para `.help(exitCode: 0)`.
public enum CASParser {
    public static func parse(_ arguments: [String]) -> CASCommand {
        guard let command = arguments.first else { return .help(exitCode: 1) }
        switch command {
        case "list": return .list
        case "current": return .current
        case "switch":
            guard arguments.count >= 2, !arguments[1].isEmpty else { return .help(exitCode: 1) }
            return .switchProfile(arguments[1])
        case "sync": return arguments.count == 1 ? .sync : .help(exitCode: 1)
        case "search":
            var limit = 20
            var words: [String] = []
            var index = 1
            while index < arguments.count {
                if arguments[index] == "--limit" {
                    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { return .help(exitCode: 1) }
                    limit = value
                    index += 2
                } else {
                    words.append(arguments[index])
                    index += 1
                }
            }
            let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? .help(exitCode: 1) : .search(text, limit: limit)
        case "restore":
            var id: String?
            var profile: String?
            var index = 1
            while index < arguments.count {
                if arguments[index] == "--profile" {
                    guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else { return .help(exitCode: 1) }
                    profile = arguments[index + 1]
                    index += 2
                } else {
                    guard id == nil, !arguments[index].isEmpty else { return .help(exitCode: 1) }
                    id = arguments[index]
                    index += 1
                }
            }
            guard let id else { return .help(exitCode: 1) }
            return .restore(id, profile: profile)
        case "db": return .db(Array(arguments.dropFirst()))
        case "help", "--help", "-h": return .help(exitCode: 0)
        default: return .help(exitCode: 1)
        }
    }
}
