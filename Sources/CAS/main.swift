import Foundation
import ClaudeAccountSwitcherCore

// Helper de i18n mínimo. `AppStrings` vive no target da app (SwiftUI/AppKit) e não é acessível
// aqui; a CLI depende só do Core. Replicamos a mesma regra de idioma para manter as saídas
// bilíngues (pt-BR / en-US) sem arrastar dependências.
func t(_ pt: String, _ en: String) -> String {
    Locale.current.language.languageCode?.identifier == "pt" ? pt : en
}

/// Mesmo diretório raiz gerenciado que o app usa (ver `MenuBarController`), para a CLI enxergar
/// exatamente os mesmos perfis e o mesmo `active-profile.json`.
func managedRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Account Switcher", isDirectory: true)
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usage() -> String {
    t("""
    Uso: cas <comando>

      list             Lista os perfis (a conta ativa é marcada com *)
      current          Mostra a conta ativa
      switch <alvo>    Ativa o perfil cujo nome ou email é exatamente <alvo>

    Cópia local das sessões (banco SQLite, atualizado pelo app a cada 5 min):
      sync                              Copia agora as sessões de todos os perfis
      search <texto> [--limit N]        Busca nas conversas arquivadas
      restore <id> [--profile <alvo>]   Recria no disco uma sessão arquivada (ex.: apagada pelo CLI)
      db [sql]                          Abre o banco no sqlite3 (somente leitura)
    """, """
    Usage: cas <command>

      list             List profiles (the active account is marked with *)
      current          Show the active account
      switch <target>  Activate the profile whose name or email equals <target>

    Local session copy (SQLite database, refreshed by the app every 5 min):
      sync                               Copy every profile's sessions now
      search <text> [--limit N]          Search archived conversations
      restore <id> [--profile <target>]  Recreate an archived session on disk (e.g. deleted by the CLI)
      db [sql]                           Open the database in sqlite3 (read-only)
    """)
}

func label(_ profile: Profile) -> String {
    let email = profile.email ?? "-"
    return "\(profile.name) (\(email))"
}

func runList(_ store: ProfileStore) throws {
    let profiles = try store.list()
    guard !profiles.isEmpty else {
        print(t("Nenhum perfil configurado. Use o app para criar um.", "No profiles configured. Use the app to create one."))
        return
    }
    let activeID = try store.active()?.id
    for profile in profiles {
        let mark = profile.id == activeID ? "*" : " "
        let email = profile.email ?? "-"
        print("\(mark) \(profile.name)\t\(email)")
    }
}

func runCurrent(_ store: ProfileStore) throws {
    guard let active = try store.active(),
          let profile = try store.list().first(where: { $0.id == active.id }) else {
        printErr(t("Nenhuma conta ativa. Use `cas switch <alvo>`.", "No active account. Use `cas switch <target>`."))
        exit(1)
    }
    print(label(profile))
}

func runSwitch(_ store: ProfileStore, root: URL, query: String) async throws {
    let profiles = try store.list()
    switch ProfileResolver.resolve(profiles, query: query) {
    case .notFound:
        printErr(t("Erro: nenhum perfil corresponde a \"\(query)\". Use `cas list`.",
                   "Error: no profile matches \"\(query)\". Use `cas list`."))
        exit(1)
    case .ambiguous(let matches):
        let options = matches.map { $0.email ?? $0.name }.joined(separator: ", ")
        printErr(t("Erro: \"\(query)\" é ambíguo. Desambigue pelo email: \(options).",
                   "Error: \"\(query)\" is ambiguous. Disambiguate by email: \(options)."))
        exit(1)
    case .found(let profile):
        // Mesmo efeito da GUI (active-profile.json + launchctl setenv + symlink do Paseo), mas SEM
        // sincronizar o app desktop: relançar a GUI só faz sentido a partir da própria GUI.
        let service = ActivationService(
            store: store,
            launchd: SystemLaunchdEnvironment(),
            paseoIntegration: PaseoIntegration(appSupport: root)
        )
        let result = try await service.activate(profile, syncDesktopApp: false)
        print(t("Conta ativa: \(label(result.profile)). Novos processos \"claude\" usarão este perfil.",
                "Active account: \(label(result.profile)). New \"claude\" processes will use this profile."))
    }
}

func archive() -> SessionArchive { SessionArchive(appSupport: managedRoot()) }

func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func runSync(_ store: ProfileStore) throws {
    let started = Date()
    let report = try archive().sync(profiles: try store.list())
    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
    print(t("Arquivos: \(report.filesSeen) · atualizados: \(report.filesUpdated) · linhas novas: \(report.linesAdded) · revisões: \(report.revisionsCreated) · removidos do disco: \(report.filesMarkedDeleted) · \(seconds) s",
            "Files: \(report.filesSeen) · updated: \(report.filesUpdated) · new lines: \(report.linesAdded) · revisions: \(report.revisionsCreated) · gone from disk: \(report.filesMarkedDeleted) · \(seconds) s"))
    for error in report.errors { printErr(t("Aviso: \(error)", "Warning: \(error)")) }
}

func runSearch(_ text: String, limit: Int) throws {
    let hits = try archive().search(text, limit: limit)
    guard !hits.isEmpty else {
        print(t("Nada encontrado.", "Nothing found."))
        return
    }
    for hit in hits {
        let when = hit.timestamp.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "-"
        let gone = hit.deleted ? t(" (apagada do disco)", " (deleted from disk)") : ""
        print("\(when)  \(hit.profileName ?? hit.profileID)  \(hit.resumeID)\(gone)")
        if let cwd = hit.cwd { print("  \(cwd)") }
        print("  \(hit.type == "user" ? ">" : "<") \(hit.snippet)")
    }
}

func runRestore(_ store: ProfileStore, id: String, profileQuery: String?) throws {
    let candidates = try archive().candidates(sessionPrefix: id)
    guard !candidates.isEmpty else {
        printErr(t("Erro: nenhuma sessão arquivada começa com \"\(id)\". Use `cas search`.",
                   "Error: no archived session starts with \"\(id)\". Use `cas search`."))
        exit(1)
    }
    let ids = Set(candidates.map(\.sessionID))
    guard ids.count == 1, let sessionID = ids.first else {
        printErr(t("Erro: \"\(id)\" é ambíguo: \(ids.sorted().joined(separator: ", ")).",
                   "Error: \"\(id)\" is ambiguous: \(ids.sorted().joined(separator: ", "))."))
        exit(1)
    }
    let profiles = try store.list()
    let destination: Profile
    if let profileQuery {
        guard case .found(let profile) = ProfileResolver.resolve(profiles, query: profileQuery) else {
            printErr(t("Erro: nenhum perfil único corresponde a \"\(profileQuery)\". Use `cas list`.",
                       "Error: no single profile matches \"\(profileQuery)\". Use `cas list`."))
            exit(1)
        }
        destination = profile
    } else {
        let owners = candidates.compactMap { candidate in profiles.first { $0.id.uuidString == candidate.profileID } }
        guard owners.count == 1, let owner = owners.first else {
            let detail = owners.isEmpty
                ? t("o perfil de origem não existe mais", "its profile no longer exists")
                : t("ela existe em mais de um perfil", "it exists in more than one profile")
            printErr(t("Erro: escolha o perfil de destino com --profile <nome|email> (\(detail)).",
                       "Error: choose the destination profile with --profile <name|email> (\(detail))."))
            exit(1)
        }
        destination = owner
    }
    // Copia do próprio perfil de destino se ele tiver a sessão; senão do único que tem.
    let source = candidates.first { $0.profileID == destination.id.uuidString } ?? candidates[0]
    let result = try archive().restore(sessionID: sessionID, fromProfileID: source.profileID, into: destination.directory)
    print(t("Sessão \(sessionID) → \(label(destination)): \(result.written.count) arquivo(s) recriado(s), \(result.alreadyPresent.count) já existia(m).",
            "Session \(sessionID) → \(label(destination)): \(result.written.count) file(s) recreated, \(result.alreadyPresent.count) already present."))
    let resume = "claude --resume \(sessionID)"
    print(t("Para retomar:", "To resume:"))
    print("  " + (result.cwd.map { "cd \(shellQuoted($0)) && \(resume)" } ?? resume))
}

func runDB(_ extra: [String]) -> Never {
    let path = archive().databaseURL.path
    guard FileManager.default.fileExists(atPath: path) else {
        printErr(t("Erro: o banco ainda não existe (\(path)). Rode `cas sync`.", "Error: the database does not exist yet (\(path)). Run `cas sync`."))
        exit(1)
    }
    let arguments = ["sqlite3", "-readonly", path] + extra
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    execv("/usr/bin/sqlite3", &argv)
    printErr(t("Erro: não foi possível abrir /usr/bin/sqlite3.", "Error: could not run /usr/bin/sqlite3."))
    exit(1)
}

let command = CASParser.parse(Array(CommandLine.arguments.dropFirst()))

do {
    switch command {
    case .help(let code):
        if code == 0 { print(usage()) } else { printErr(usage()) }
        exit(code)
    case .list:
        try runList(try ProfileStore(root: managedRoot()))
    case .current:
        try runCurrent(try ProfileStore(root: managedRoot()))
    case .switchProfile(let query):
        let root = managedRoot()
        try await runSwitch(try ProfileStore(root: root), root: root, query: query)
    case .sync:
        try runSync(try ProfileStore(root: managedRoot()))
    case .search(let text, let limit):
        try runSearch(text, limit: limit)
    case .restore(let id, let profile):
        try runRestore(try ProfileStore(root: managedRoot()), id: id, profileQuery: profile)
    case .db(let extra):
        runDB(extra)
    }
} catch {
    printErr(t("Erro: \(error)", "Error: \(error)"))
    exit(1)
}
