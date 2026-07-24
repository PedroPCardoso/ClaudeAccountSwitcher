import Foundation

/// Comando reconhecido pela CLI `cas`. `help` carrega o código de saída desejado para que o
/// dispatch (uso incorreto → exit ≠ 0; ajuda explícita → exit 0) seja decidido de forma pura,
/// sem chamar `exit()` — o que permite testar o parsing isoladamente.
public enum CASCommand: Equatable, Sendable {
    case list
    case current
    case switchProfile(String)
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
        case "help", "--help", "-h": return .help(exitCode: 0)
        default: return .help(exitCode: 1)
        }
    }
}
