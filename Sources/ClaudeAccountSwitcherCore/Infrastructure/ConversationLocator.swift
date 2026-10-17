import Foundation

/// Uma conversa do Claude Code encontrada em algum perfil.
public struct ConversationMatch: Equatable, Sendable {
    public let profile: Profile
    public let sessionID: String
    public let cwd: String?
    public let modifiedAt: Date
    public let file: URL

    /// Comando pronto para retomar: troca para o perfil, entra na pasta e faz `--resume`.
    public var resumeCommand: String {
        var parts = ["cas switch \(Self.quoted(profile.name))"]
        if let cwd { parts.append("cd \(Self.quoted(cwd))") }
        parts.append("claude --resume \(sessionID)")
        return parts.joined(separator: " && ")
    }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Responde "onde está minha conversa?": a troca de perfil não move transcripts, então uma
/// conversa iniciada em outro perfil só aparece no `--resume` daquele perfil. Procura em
/// `projects/<slug>/<sessionId>.jsonl` de todos os perfis por prefixo do sessionId ou por
/// trecho do diretório de trabalho (slug da pasta ou `cwd` gravado nas primeiras linhas).
public enum ConversationLocator {
    public static func find(query: String, profiles: [Profile], limit: Int = 20) -> [ConversationMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let slugNeedle = slug(needle)
        var matches: [ConversationMatch] = []
        for profile in profiles {
            let projects = profile.directory.appendingPathComponent("projects", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let sessionID = url.deletingPathExtension().lastPathComponent
                let folderSlug = url.deletingLastPathComponent().lastPathComponent.lowercased()
                let cwd = firstCwd(in: url)
                let hit = sessionID.lowercased().hasPrefix(needle) || folderSlug.contains(slugNeedle) || (cwd?.lowercased().contains(needle) ?? false)
                guard hit else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                matches.append(ConversationMatch(profile: profile, sessionID: sessionID, cwd: cwd, modifiedAt: modified, file: url))
            }
        }
        return Array(matches.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }

    /// Mesma transformação que o CLI usa para nomear a pasta do projeto: `/` e `.` viram `-`.
    static func slug(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// Lê só o começo do arquivo (as primeiras linhas trazem `cwd`); transcripts podem ter MBs.
    static func firstCwd(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 64 * 1024)
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n").prefix(60) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let cwd = object["cwd"] as? String { return cwd }
        }
        return nil
    }
}
