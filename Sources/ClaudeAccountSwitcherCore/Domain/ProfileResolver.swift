import Foundation

/// Resultado de resolver uma query (`cas switch <query>`) contra a lista de perfis.
public enum ProfileResolution: Equatable, Sendable {
    case found(Profile)
    case notFound
    case ambiguous([Profile])
}

/// Resolução pura (sem I/O) de um perfil a partir de uma query de texto. Match EXATO por nome
/// OU email: 0 correspondências → `.notFound`; exatamente 1 → `.found`; mais de 1 → `.ambiguous`.
/// Mantida no domínio para ser testável sem tocar em disco ou processos.
public enum ProfileResolver {
    public static func resolve(_ profiles: [Profile], query: String) -> ProfileResolution {
        let matches = profiles.filter { $0.name == query || $0.email == query }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }
}
