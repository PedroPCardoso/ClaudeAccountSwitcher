import Foundation

/// Uma sessão do Claude Code em execução dentro de um perfil, lida do marcador
/// `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` que o próprio CLI grava ao iniciar.
public struct RunningSession: Equatable, Sendable {
    public let pid: pid_t
    public let sessionID: String?
    public let cwd: String?
    public let status: String?
}

/// Detecta processos `claude` vivos que usam um perfil. Serve para avisar antes de operações
/// destrutivas (remover o perfil apaga o diretório onde essas sessões gravam transcript, estado
/// e `.claude.json`) — a troca de perfil em si não afeta processos já abertos.
///
/// Heurística: o CLI escreve `sessions/<pid>.json` e nem sempre o remove ao sair (crash, kill),
/// então cada pid é confirmado com `kill(pid, 0)`. Marcadores de pids mortos são ignorados.
public enum SessionActivity {
    public static func runningSessions(in profileDirectory: URL) -> [RunningSession] {
        let sessions = profileDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { entry -> RunningSession? in
            guard entry.pathExtension == "json", let pid = pid_t(entry.deletingPathExtension().lastPathComponent), isAlive(pid) else { return nil }
            let raw = (try? Data(contentsOf: entry)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // O nome do arquivo já é o pid; o JSON só enriquece. Se não parsear, ainda conta como viva.
            return RunningSession(pid: pid, sessionID: raw?["sessionId"] as? String, cwd: raw?["cwd"] as? String, status: raw?["status"] as? String)
        }.sorted { $0.pid < $1.pid }
    }

    /// `kill(pid, 0)` não envia sinal: só testa existência. EPERM significa que o processo existe
    /// mas pertence a outro usuário — ainda está vivo.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
