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
    """, """
    Usage: cas <command>

      list             List profiles (the active account is marked with *)
      current          Show the active account
      switch <target>  Activate the profile whose name or email equals <target>
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
    }
} catch {
    printErr(t("Erro: \(error)", "Error: \(error)"))
    exit(1)
}
