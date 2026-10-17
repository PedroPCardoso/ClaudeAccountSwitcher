import Foundation

/// Lógica pura de reparo quando `active-profile.json` está corrompido ou aponta para um perfil
/// que não existe mais. Preferência: o perfil cujo diretório coincide com o `CLAUDE_CONFIG_DIR`
/// que o launchd ainda guarda (foi a última troca bem-sucedida); senão, o de uso mais recente.
public enum ActiveStateRepair {
    public static func suggestion(profiles: [Profile], launchdDirectory: String?) -> Profile? {
        if let launchdDirectory {
            let wanted = URL(fileURLWithPath: launchdDirectory).standardizedFileURL.path
            if let match = profiles.first(where: { $0.directory.standardizedFileURL.path == wanted }) { return match }
        }
        return profiles.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }
}
