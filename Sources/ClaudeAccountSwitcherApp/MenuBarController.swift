import AppKit
import ClaudeAccountSwitcherCore

/// User-facing switch behaviour flags persisted in `UserDefaults`.
enum AppPreferences {
    /// When enabled, switching accounts quits and relaunches the native desktop app for the
    /// chosen profile. Disabled by default so a switch does not disrupt an open desktop app.
    static let relaunchDesktopOnSwitch = "relaunchDesktopOnSwitch"

    /// When enabled, a desktop app that ignores the quit request is force-killed after the grace
    /// period. Off by default: killing Electron mid-write can corrupt its session storage.
    static let forceQuitDesktopOnSwitch = "forceQuitDesktopOnSwitch"

    /// Legacy Bool key for the menu-bar usage badge. Prefer `StatusBarUsageSource.defaultsKey`.
    static let showUsageInMenuBar = StatusBarUsageSource.legacyDefaultsKey

    /// UUIDs (as strings) of the profiles included in the aggregate usage analysis. Absent key
    /// = every profile selected (the obvious first-run default). See `AnalysisSelection` for the
    /// pure selection logic.
    static let analysisSelectedProfileIDs = "analysisSelectedProfileIDs"

    /// Raw persisted selection, or `nil` when the key was never written (→ all selected).
    static func analysisSavedRawIDs() -> [String]? {
        UserDefaults.standard.object(forKey: analysisSelectedProfileIDs) as? [String]
    }

    static func setAnalysisSelection(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: analysisSelectedProfileIDs)
    }

    static func analysisSelectedProfiles(from profiles: [Profile]) -> [Profile] {
        AnalysisSelection.selected(from: profiles, savedRawIDs: analysisSavedRawIDs())
    }

    static var statusBarUsageSource: StatusBarUsageSource {
        StatusBarUsageSource.resolve()
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Any?
    private let store: ProfileStore
    private let activation: ActivationService
    private let auth: ClaudeAuthService
    private let usage = ClaudeUsageService()
    private let cursorCredentials = CursorCredentialStore()
    private let cursorUsage: CursorUsageService
    private let cursorUsageStore: CursorUsageStore
    private let migration: MigrationService
    private let shell: ShellIntegrationManager
    private let locator: ClaudeLocator
    private let loginItem = LoginItemService()
    private let paseo: PaseoIntegration
    private let keychain = KeychainCredentials()
    private let desktopClient = SystemDesktopAppClient(allowsForceTerminate: { UserDefaults.standard.bool(forKey: AppPreferences.forceQuitDesktopOnSwitch) })
    private var preferencesWindowController: PreferencesWindowController?
    private var usageWindowController: UsageWindowController?
    private var analysisWindowController: AnalysisWindowController?
    private var cursorUsageWindowController: CursorUsageWindowController?
    private var cursorAnalysisWindowController: CursorAnalysisWindowController?
    private var usageRefreshTimer: Timer?
    private var isRefreshingUsage = false
    private var cursorSnapshot: CursorUsageSnapshot?
    private var fiveHourAlert = FiveHourAlertTracker()
    private var weeklyCreditsAlert = WeeklyCreditsAlertTracker()
    private var cursorBudgetAlert = CursorBudgetAlertTracker()

    override init() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude Account Switcher", isDirectory: true)
        do {
            store = try ProfileStore(root: root)
        } catch {
            // Sem o store não há como operar; em vez de crashar sem diagnóstico
            // (disco cheio, permissão, sandbox), mostra um alerta nativo e sai.
            MenuBarController.presentStartupFailure(root: root, error: error)
        }
        let cursorStore: CursorUsageStore
        do {
            cursorStore = try CursorUsageStore(root: root)
        } catch {
            MenuBarController.presentStartupFailure(root: root, error: error)
        }
        cursorUsageStore = cursorStore
        cursorSnapshot = try? cursorStore.load()
        let credentials = cursorCredentials
        cursorUsage = CursorUsageService(credentialProvider: { try credentials.credentials() })
        let locator = ClaudeLocator()
        self.locator = locator
        auth = ClaudeAuthService(locator: locator)
        shell = ShellIntegrationManager(appSupport: root)
        migration = MigrationService(store: store)
        paseo = PaseoIntegration(appSupport: root)
        activation = ActivationService(store: store, desktopActivator: DesktopAppActivator(client: desktopClient), paseoIntegration: paseo)
        super.init()
    }

    /// Apresenta um alerta nativo com diagnóstico quando o armazenamento de perfis não
    /// pode ser inicializado e encerra a app de forma controlada (nunca retorna).
    /// O binário `cas` é empacotado como irmão do executável da app em `Contents/MacOS/`
    /// (ver Scripts/build-app.sh), e em desenvolvimento fica ao lado dele em `.build/<config>/`.
    /// Só retorna o caminho se o arquivo existir, para não instalar um symlink quebrado.
    private static func bundledCASBinary() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let cas = executable.deletingLastPathComponent().appendingPathComponent("cas")
        return FileManager.default.fileExists(atPath: cas.path) ? cas : nil
    }

    private static func presentStartupFailure(root: URL, error: Error) -> Never {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = AppStrings.t(
            "Não foi possível iniciar o Claude Account Switcher",
            "Could not start Claude Account Switcher")
        alert.informativeText = AppStrings.t(
            "Falha ao preparar o diretório de dados em:\n\(root.path)\n\nVerifique espaço em disco e permissões e tente novamente.\n\nDetalhe: \(error.localizedDescription)",
            "Failed to prepare the data directory at:\n\(root.path)\n\nCheck available disk space and permissions, then try again.\n\nDetail: \(error.localizedDescription)")
        alert.addButton(withTitle: AppStrings.t("Sair", "Quit"))
        alert.runModal()
        exit(1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let logoURL = Bundle.main.url(forResource: "claude-account-switcher-logo", withExtension: "png"), let logo = NSImage(contentsOf: logoURL) {
            logo.size = NSSize(width: 18, height: 18)
            logo.isTemplate = false
            statusItem.button?.image = logo
            statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude accounts")
        }
        installShortcutMonitor(); rebuildMenu(); refreshProfileMetadata()
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProfileMetadata() }
        }
        // Reflete a mudança do toggle "mostrar uso na barra" imediatamente, sem esperar o
        // próximo refresh de 60s.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItemUsage() }
        }
        if let official = try? locator.locate() { try? shell.install(home: FileManager.default.homeDirectoryForCurrentUser, officialBinary: official, casBinary: MenuBarController.bundledCASBinary()) }
        if let active = try? store.active() { try? SystemLaunchdEnvironment().set(active.directory.path); try? paseo.updateSymlink(to: active.directory) }
        try? loginItem.setEnabled(true)
    }

    /// `nil` quando o estado ativo é legível e aponta para um perfil existente; senão o motivo.
    private func activeStateProblem(profiles: [Profile]) -> String? {
        do {
            guard let active = try store.active() else { return nil }
            if !profiles.contains(where: { $0.id == active.id }) {
                return AppStrings.t("Estado ativo aponta para um perfil que não existe mais", "Active state points to a profile that no longer exists")
            }
            return nil
        } catch {
            return AppStrings.t("Arquivo de estado ativo ilegível", "Active state file is unreadable")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let profiles = (try? store.list()) ?? []
        let active = (try? store.active())??.id
        if let problem = activeStateProblem(profiles: profiles) {
            // Antes isso virava "nenhum perfil ativo" em silêncio, com o launcher recusando rodar.
            let repair = NSMenuItem(title: "⚠️ " + problem + AppStrings.t(" — reparar…", " — repair…"), action: #selector(repairActiveState), keyEquivalent: "")
            repair.target = self; menu.addItem(repair); menu.addItem(.separator())
        }
        if profiles.isEmpty {
            menu.addItem(withTitle: AppStrings.t("Nenhum perfil importado", "No profiles imported"), action: nil, keyEquivalent: "")
        } else {
            for profile in profiles {
                let item = NSMenuItem(title: profile.name + (profile.email.map { " — \($0)" } ?? ""), action: #selector(selectProfile(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = profile; item.state = profile.id == active ? .on : .off
                item.toolTip = usageTooltip(for: profile)
                menu.addItem(item)
                let usage = NSMenuItem(title: usageSummary(for: profile), action: nil, keyEquivalent: "")
                usage.isEnabled = false; usage.indentationLevel = 1; menu.addItem(usage)
                if let renewal = renewalSummary(for: profile) {
                    let renewalItem = NSMenuItem(title: renewal, action: nil, keyEquivalent: "")
                    renewalItem.isEnabled = false; renewalItem.indentationLevel = 1; menu.addItem(renewalItem)
                }
            }
        }
        menu.addItem(.separator())
        let usageItem = NSMenuItem(title: AppStrings.t("Ver uso no Claude…", "View Claude usage…"), action: #selector(openUsage), keyEquivalent: "")
        usageItem.target = self
        usageItem.toolTip = AppStrings.t("Abre o painel visual com uso e tokens de todas as contas", "Opens the visual panel with usage and tokens for every account")
        menu.addItem(usageItem)
        let analysisItem = NSMenuItem(title: AppStrings.t("Analisar uso agregado…", "Analyze aggregate usage…"), action: #selector(openAnalysis), keyEquivalent: "")
        analysisItem.target = self
        analysisItem.toolTip = AppStrings.t("Compara o consumo somado das contas escolhidas: 1 Max vs 2–3 Pro", "Compares summed usage of the chosen accounts: 1 Max vs 2–3 Pro")
        menu.addItem(analysisItem)
        let locateItem = NSMenuItem(title: AppStrings.t("Onde está minha conversa?…", "Where is my conversation?…"), action: #selector(locateConversation), keyEquivalent: "")
        locateItem.target = self
        locateItem.toolTip = AppStrings.t("Procura uma sessão pelo id ou pela pasta em todos os perfis e monta o comando --resume", "Finds a session by id or folder across every profile and builds the --resume command")
        menu.addItem(locateItem)
        let maintenanceItem = NSMenuItem(title: AppStrings.t("Manutenção…", "Maintenance…"), action: #selector(runMaintenance), keyEquivalent: "")
        maintenanceItem.target = self
        maintenanceItem.toolTip = AppStrings.t("Remove backups antigos, temporários do CLI, diretórios órfãos e credenciais de perfis removidos", "Removes old backups, CLI temp files, orphaned directories and credentials of removed profiles")
        menu.addItem(maintenanceItem)

        if CursorMonitoring.isEnabled() {
            menu.addItem(.separator())
            let cursorHeader = NSMenuItem(title: AppStrings.t("Cursor", "Cursor"), action: nil, keyEquivalent: "")
            cursorHeader.isEnabled = false
            menu.addItem(cursorHeader)
            for summary in cursorUsageSummary() {
                let summaryItem = NSMenuItem(title: "    " + summary, action: nil, keyEquivalent: "")
                summaryItem.isEnabled = false
                summaryItem.indentationLevel = 1
                menu.addItem(summaryItem)
            }
            let cursorUsageItem = NSMenuItem(title: AppStrings.t("Ver uso no Cursor…", "View Cursor usage…"), action: #selector(openCursorUsage), keyEquivalent: "")
            cursorUsageItem.target = self
            menu.addItem(cursorUsageItem)
            let cursorAnalysisItem = NSMenuItem(title: AppStrings.t("Analisar uso do Cursor…", "Analyze Cursor usage…"), action: #selector(openCursorAnalysis), keyEquivalent: "")
            cursorAnalysisItem.target = self
            menu.addItem(cursorAnalysisItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: AppStrings.t("Preferências…", "Preferences…"), action: #selector(preferences), keyEquivalent: ","); menu.items.last?.target = self
        menu.addItem(withTitle: AppStrings.t("Sair", "Quit"), action: #selector(quit), keyEquivalent: "q"); menu.items.last?.target = self
        statusItem.menu = menu
        updateStatusItemUsage()
    }

    /// Compõe o botão do status item: imagem sempre; e, conforme `StatusBarUsageSource`,
    /// o percentual Claude e/ou Cursor em texto negrito colorido por faixa (`UsageTier`).
    private func updateStatusItemUsage() {
        guard let button = statusItem?.button else { return }
        func showIconOnly() {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            statusItem.length = NSStatusItem.squareLength
        }
        let source = AppPreferences.statusBarUsageSource
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        let activeUsage = profiles.first(where: { $0.id == activeID })?.usage
        let segments = StatusBarUsage.segments(
            source: source,
            activeClaude: activeUsage,
            cursor: cursorSnapshot)
        guard !segments.isEmpty else { showIconOnly(); return }

        let font = usageBadgeFont()
        let composed = NSMutableAttributedString(string: " ")
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                composed.append(NSAttributedString(string: " | ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: font
                ]))
            }
            composed.append(NSAttributedString(string: segment.text, attributes: [
                .foregroundColor: statusColor(for: segment.tier),
                .font: font
            ]))
        }
        button.imagePosition = .imageLeft
        button.attributedTitle = composed
        statusItem.length = NSStatusItem.variableLength
    }

    /// Cor por faixa de uso na barra de menu: verde < 70, laranja 70–89, vermelho >= 90.
    private func statusColor(for tier: UsageTier) -> NSColor {
        switch tier {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Fonte do percentual: SF Rounded, bold, com dígitos monoespaçados (largura estável entre
    /// atualizações e aparência mais moderna que a system font padrão).
    private func usageBadgeFont() -> NSFont {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        if let rounded = mono.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: rounded, size: 13) { return font }
        return mono
    }

    private var relaunchDesktopOnSwitch: Bool { UserDefaults.standard.bool(forKey: AppPreferences.relaunchDesktopOnSwitch) }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        Task { do { let result = try await activation.activate(profile, syncDesktopApp: relaunchDesktopOnSwitch); fiveHourAlert.reset(); rebuildMenu(); notify(activationResult: result) } catch { showError(error) } }
    }

    @objc private func repairActiveState() {
        let profiles = (try? store.list()) ?? []
        guard let suggestion = ActiveStateRepair.suggestion(profiles: profiles, launchdDirectory: SystemLaunchdEnvironment().get()) else {
            showError(NSError(domain: "Claude Account Switcher", code: 6, userInfo: [NSLocalizedDescriptionKey: AppStrings.t("Nenhum perfil disponível para restaurar. Adicione ou importe uma conta.", "No profile available to restore. Add or import an account.")]))
            return
        }
        let alert = NSAlert()
        alert.messageText = AppStrings.t("Reparar estado ativo?", "Repair active state?")
        alert.informativeText = AppStrings.t(
            "O arquivo active-profile.json está inválido, e por isso o comando claude no terminal recusa rodar. Sugestão (pela variável do launchd ou pelo último uso): \(suggestion.name)\(suggestion.email.map { " — \($0)" } ?? ""). Você pode escolher outro perfil no menu em vez disso.",
            "active-profile.json is invalid, so the claude command in the terminal refuses to run. Suggestion (from the launchd variable or last use): \(suggestion.name)\(suggestion.email.map { " — \($0)" } ?? ""). You can pick another profile from the menu instead.")
        alert.addButton(withTitle: AppStrings.t("Restaurar \(suggestion.name)", "Restore \(suggestion.name)")); alert.addButton(withTitle: AppStrings.t("Cancelar", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { let result = try await activation.activate(suggestion, syncDesktopApp: false); fiveHourAlert.reset(); rebuildMenu(); refreshPreferences(); notify(activationResult: result) } catch { showError(error) } }
    }

    @objc private func locateConversation() {
        let profiles = (try? store.list()) ?? []
        let field = NSTextField(string: ""); field.placeholderString = AppStrings.t("id da sessão ou trecho da pasta (ex.: Develop/api)", "session id or folder fragment (e.g. Develop/api)")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let ask = NSAlert(); ask.messageText = AppStrings.t("Onde está minha conversa?", "Where is my conversation?")
        ask.informativeText = AppStrings.t("Trocar de perfil não move conversas: cada uma fica no perfil em que foi iniciada. Informe o id da sessão ou um trecho do diretório do projeto.", "Switching profiles does not move conversations: each one stays in the profile it was started in. Enter the session id or a fragment of the project directory.")
        ask.accessoryView = field; ask.addButton(withTitle: AppStrings.t("Procurar", "Search")); ask.addButton(withTitle: AppStrings.t("Cancelar", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let matches = ConversationLocator.find(query: field.stringValue, profiles: profiles, limit: 8)
        let result = NSAlert()
        guard !matches.isEmpty else {
            result.messageText = AppStrings.t("Nenhuma conversa encontrada", "No conversation found")
            result.informativeText = AppStrings.t("Nada em \(profiles.count) perfil(is) casa com “\(field.stringValue)”.", "Nothing in \(profiles.count) profile(s) matches “\(field.stringValue)”.")
            result.runModal(); return
        }
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        result.messageText = AppStrings.t("\(matches.count) conversa(s) encontrada(s)", "\(matches.count) conversation(s) found")
        result.informativeText = matches.map { match in
            "• \(match.profile.name) — \(formatter.string(from: match.modifiedAt))\n  \(match.cwd ?? match.file.deletingLastPathComponent().lastPathComponent)\n  \(match.resumeCommand)"
        }.joined(separator: "\n\n")
        result.addButton(withTitle: AppStrings.t("Copiar comando da mais recente", "Copy most recent command")); result.addButton(withTitle: AppStrings.t("Fechar", "Close"))
        if result.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(matches[0].resumeCommand, forType: .string)
            notify(AppStrings.t("Comando copiado — cole no terminal", "Command copied — paste it in the terminal"))
        }
    }

    @objc private func runMaintenance() {
        let service = MaintenanceService(store: store, appSupport: store.root, keychain: keychain)
        let report: MaintenanceReport
        do { report = try service.scan() } catch { showError(error); return }
        let alert = NSAlert()
        guard !report.isEmpty else {
            alert.messageText = AppStrings.t("Nada para limpar", "Nothing to clean"); alert.informativeText = AppStrings.t("Sem backups antigos, temporários, diretórios órfãos ou credenciais de perfis removidos.", "No old backups, temp files, orphaned directories or credentials of removed profiles.")
            alert.runModal(); return
        }
        alert.messageText = AppStrings.t("Limpar resíduos?", "Clean up leftovers?")
        alert.informativeText = [
            AppStrings.t("• \(report.shellBackups.count) backup(s) antigo(s) de dotfiles (mantém os 5 mais recentes de cada)", "• \(report.shellBackups.count) old dotfile backup(s) (keeps the 5 most recent of each)"),
            AppStrings.t("• \(report.claudeTempFiles.count) temporário(s) .claude.json.tmp.* com mais de 7 dias", "• \(report.claudeTempFiles.count) .claude.json.tmp.* temp file(s) older than 7 days"),
            AppStrings.t("• \(report.orphanedDirectories.count) diretório(s) de perfil órfão(s) em Profiles/", "• \(report.orphanedDirectories.count) orphaned profile director(ies) in Profiles/"),
            AppStrings.t("• \(report.staleKeychainServices.count) credencial(is) no Keychain de perfis que já não existem", "• \(report.staleKeychainServices.count) Keychain credential(s) of profiles that no longer exist"),
            "",
            AppStrings.t("Perfis, sessões e o .claude.json real não são tocados.", "Profiles, sessions and the real .claude.json are not touched.")
        ].joined(separator: "\n")
        alert.alertStyle = .warning; alert.addButton(withTitle: AppStrings.t("Limpar", "Clean")); alert.addButton(withTitle: AppStrings.t("Cancelar", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = service.apply(report)
        rebuildMenu(); notify(AppStrings.t("Manutenção concluída: \(removed) item(ns) removido(s)", "Maintenance done: \(removed) item(s) removed"))
    }

    @objc private func addAccount() {
        let alert = NSAlert(); alert.messageText = "Adicionar conta Claude"; alert.informativeText = "Escolha o tipo de autenticação. O navegador abrirá para concluir o login."; alert.addButton(withTitle: "Claude Pro/Max"); alert.addButton(withTitle: "Anthropic Console"); alert.addButton(withTitle: "Cancelar")
        let response = alert.runModal(); guard response != .alertThirdButtonReturn else { return }
        let kind: ProfileKind = response == .alertSecondButtonReturn ? .anthropicConsole : .claudeSubscription
        let id = UUID(); let name = kind == .anthropicConsole ? "Anthropic Console" : "Claude Account"
        let directory: URL
        do { directory = try store.createManagedDirectory(id: id) } catch { showError(error); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.auth.login(profileDirectory: directory, kind: kind)
                let status = try self.auth.status(profileDirectory: directory)
                let profile = Profile(id: id, name: name, email: status.email, organization: status.organization, kind: status.kind, directory: directory, health: status.isAuthenticated ? .ready : .expired)
                try self.store.save(profile)
                DispatchQueue.main.async { self.rebuildMenu(); self.notify(AppStrings.t("Conta adicionada", "Account added")); self.offerDesktopSessionCopy(for: profile) }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    private func offerDesktopSessionCopy(for profile: Profile) {
        guard !MigrationService.hasRealDesktopSession(at: profile.desktopDirectory) else { return }
        guard MigrationService.hasRealDesktopSession(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")) else { return }
        let alert = NSAlert()
        alert.messageText = "Reaproveitar sessão do app nativo?"
        alert.informativeText = "Encontramos uma sessão já logada no app nativo do Claude. Isso só deve ser copiado para \(profile.name) se for a mesma conta que você acabou de logar — o app nativo não consegue confirmar isso sozinho."
        alert.addButton(withTitle: "Copiar"); alert.addButton(withTitle: "Não, logar depois")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try migration.copyDefaultDesktopSessionIfAvailable(into: profile, isDesktopRunning: { desktopClient.isRunning() })
            notify(AppStrings.t("Sessão do app nativo copiada para \(profile.name)", "Native app session copied to \(profile.name)"))
        } catch MigrationError.desktopAppRunning {
            showError(NSError(domain: "Claude Account Switcher", code: 7, userInfo: [NSLocalizedDescriptionKey: AppStrings.t("Feche o app nativo do Claude antes de copiar a sessão: copiar com ele aberto pode gerar uma sessão corrompida. Depois use “Refazer login” ou troque para o perfil com a reabertura do app ligada.", "Quit the native Claude app before copying the session: copying while it runs can produce a corrupted session. Then use “Sign in again” or switch to the profile with app relaunch enabled.")]))
        } catch { showError(error) }
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            _ = try migration.importDirectory(source); rebuildMenu(); notify(AppStrings.t("Perfil importado", "Profile imported"))
        } catch { showError(error) }
    }

    @objc private func renameProfile() {
        let profiles = (try? store.list()) ?? []
        guard !profiles.isEmpty else { notify(AppStrings.t("Nenhum perfil cadastrado", "No profiles registered")); return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        profiles.forEach { picker.addItem(withTitle: $0.name + ($0.email.map { " — \($0)" } ?? "")) }
        let field = NSTextField(string: profiles[0].name); field.placeholderString = "Novo nome"; field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let accessory = NSStackView(views: [picker, field]); accessory.orientation = .vertical; accessory.spacing = 8; accessory.frame = NSRect(x: 0, y: 0, width: 260, height: 62)
        let alert = NSAlert(); alert.messageText = "Renomear perfil"; alert.informativeText = "O nome é apenas um rótulo local; identidade, diretório e credenciais permanecem inalterados."; alert.accessoryView = accessory; alert.addButton(withTitle: "Salvar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = picker.indexOfSelectedItem
        guard profiles.indices.contains(index) else { return }
        renameSpecificProfile(profiles[index], proposedName: field.stringValue)
    }

    private func renameSpecificProfile(_ profile: Profile, proposedName: String? = nil) {
        let name: String
        if let proposedName {
            name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let field = NSTextField(string: profile.name); field.placeholderString = "Novo nome"
            let alert = NSAlert(); alert.messageText = "Renomear perfil"; alert.informativeText = "O nome é apenas um rótulo local; identidade, diretório e credenciais permanecem inalterados."; alert.accessoryView = field; alert.addButton(withTitle: "Salvar"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty else { showError(NSError(domain: "Claude Account Switcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Informe um nome para o perfil."])); return }
        do { try store.update(id: profile.id) { $0.name = name }; rebuildMenu(); refreshPreferences(); notify(AppStrings.t("Perfil renomeado", "Profile renamed")) } catch { showError(error) }
    }

    @objc private func openUsage() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        if usageWindowController == nil {
            usageWindowController = UsageWindowController(profiles: profiles, activeID: activeID, isRefreshing: isRefreshingUsage, onRefresh: { [weak self] in self?.refreshProfileMetadata() })
        } else {
            usageWindowController?.update(profiles: profiles, activeID: activeID, isRefreshing: isRefreshingUsage)
        }
        usageWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    @objc private func openAnalysis() {
        let profiles = (try? store.list()) ?? []
        if analysisWindowController == nil {
            analysisWindowController = AnalysisWindowController(profiles: profiles, isRefreshing: isRefreshingUsage, onRefresh: { [weak self] in self?.refreshProfileMetadata() })
        } else {
            analysisWindowController?.update(profiles: profiles, isRefreshing: isRefreshingUsage)
        }
        analysisWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    @objc private func openCursorUsage() {
        if cursorUsageWindowController == nil {
            cursorUsageWindowController = CursorUsageWindowController(
                snapshot: cursorSnapshot,
                isRefreshing: isRefreshingUsage,
                onRefresh: { [weak self] in self?.refreshProfileMetadata() })
        } else {
            cursorUsageWindowController?.update(snapshot: cursorSnapshot, isRefreshing: isRefreshingUsage)
        }
        cursorUsageWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    @objc private func openCursorAnalysis() {
        if cursorAnalysisWindowController == nil {
            cursorAnalysisWindowController = CursorAnalysisWindowController(
                snapshot: cursorSnapshot,
                isRefreshing: isRefreshingUsage,
                onRefresh: { [weak self] in self?.refreshProfileMetadata() })
        } else {
            cursorAnalysisWindowController?.update(snapshot: cursorSnapshot, isRefreshing: isRefreshingUsage)
        }
        cursorAnalysisWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    @objc private func migrateExisting() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let plan = try migration.preview(home: home)
            guard !plan.sources.isEmpty else { notify(AppStrings.t("Nenhum perfil existente encontrado", "No existing profiles found")); return }
            let alert = NSAlert(); alert.messageText = "Migrar perfis existentes?"; alert.informativeText = plan.sources.map(\.path).joined(separator: "\n") + "\n\nOs originais serão mantidos."; alert.addButton(withTitle: "Migrar"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let report = try migration.execute(plan)
            rebuildMenu(); notify(AppStrings.t("\(report.imported.count) perfil(is) migrado(s)", "\(report.imported.count) profile(s) migrated"))
        } catch { showError(error) }
    }

    @objc private func preferences() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                profiles: profiles,
                activeID: activeID,
                paseoDetected: paseo.isDetected(),
                paseoConfigured: paseo.isConfigured(),
                cursorStatus: cursorCredentialStatusText(),
                onActivate: { [weak self] profile in self?.activateFromPreferences(profile) },
                onRelogin: { [weak self] profile in self?.reloginFromPreferences(profile) },
                onRename: { [weak self] profile in self?.renameSpecificProfile(profile) },
                onRemove: { [weak self] profile in self?.removeFromPreferences(profile) },
                onUninstall: { [weak self] in self?.uninstall() },
                onAdd: { [weak self] in self?.addAccount() },
                onImport: { [weak self] in self?.importProfile() },
                onMigrate: { [weak self] in self?.migrateExisting() },
                onIntegratePaseo: { [weak self] in self?.integratePaseo() }
            )
        } else {
            preferencesWindowController?.update(
                profiles: profiles,
                activeID: activeID,
                paseoDetected: paseo.isDetected(),
                paseoConfigured: paseo.isConfigured(),
                cursorStatus: cursorCredentialStatusText())
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    private func integratePaseo() {
        guard paseo.isDetected() else {
            showError(NSError(domain: "Claude Account Switcher", code: 5, userInfo: [NSLocalizedDescriptionKey: "Paseo não encontrado (~/.paseo/config.json ausente)."]))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Integrar com Paseo?"
        alert.informativeText = "O provider \"claude\" em ~/.paseo/config.json passará a usar um link estável mantido por este app, que sempre aponta para a conta ativa. O arquivo original é copiado para Backups antes da alteração; outros providers (como \"claude-work\") não são tocados.\n\nDepois de integrar, rode \"paseo daemon restart\" no terminal uma única vez para o Paseo carregar a mudança. Trocas de conta seguintes não vão exigir reiniciar o daemon de novo."
        alert.addButton(withTitle: "Integrar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if let active = try? store.active() { try? paseo.updateSymlink(to: active.directory) }
            let backup = try paseo.integrate()
            refreshPreferences()
            notify("Paseo integrado — rode \"paseo daemon restart\" no terminal para aplicar. Backup: \(backup.lastPathComponent)")
        } catch { showError(error) }
    }

    private func refreshPreferences() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        preferencesWindowController?.update(
            profiles: profiles,
            activeID: activeID,
            paseoDetected: paseo.isDetected(),
            paseoConfigured: paseo.isConfigured(),
            cursorStatus: cursorCredentialStatusText())
        usageWindowController?.update(profiles: profiles, activeID: activeID, isRefreshing: isRefreshingUsage)
        analysisWindowController?.update(profiles: profiles, isRefreshing: isRefreshingUsage)
        cursorUsageWindowController?.update(snapshot: cursorSnapshot, isRefreshing: isRefreshingUsage)
        cursorAnalysisWindowController?.update(snapshot: cursorSnapshot, isRefreshing: isRefreshingUsage)
    }

    private func cursorCredentialStatusText() -> String {
        do {
            let creds = try cursorCredentials.credentials()
            let plan = creds.membershipType?.uppercased() ?? "?"
            let email = creds.email ?? AppStrings.t("sem e-mail", "no email")
            return AppStrings.t("Cursor: \(email) · plano \(plan)", "Cursor: \(email) · \(plan) plan")
        } catch CursorCredentialError.tokenExpired {
            return AppStrings.t("Cursor: sessão expirada — faça login de novo no app", "Cursor: session expired — sign in again in the app")
        } catch {
            return AppStrings.t("Cursor não autenticado — faça login no app", "Cursor not signed in — sign in to the app")
        }
    }

    private func cursorUsageSummary() -> [String] {
        guard let plan = cursorSnapshot?.planUsage else {
            return [AppStrings.t("Uso indisponível", "Usage unavailable")]
        }
        let reset = QuotaFormatter.resetDescription(plan.billingCycleEnd)
        var lines: [String] = []
        var buckets: [String] = []
        if let cursorModels = plan.cursorModelsPercent {
            buckets.append(AppStrings.t(
                "Modelos Cursor \(Int(cursorModels.rounded()))%",
                "Cursor Models \(Int(cursorModels.rounded()))%"))
        }
        if let otherModels = plan.otherModelsPercent {
            buckets.append(AppStrings.t(
                "Outros modelos \(Int(otherModels.rounded()))%",
                "Other Models \(Int(otherModels.rounded()))%"))
        }
        if !buckets.isEmpty {
            lines.append(buckets.joined(separator: " · ") + " · " + AppStrings.t("renova \(reset)", "resets \(reset)"))
        }
        let spent = String(format: "$%.2f", plan.totalSpendCents / 100)
        let limit = String(format: "$%.2f", plan.limitCents / 100)
        lines.append(AppStrings.t(
            "Gasto do ciclo \(spent) de \(limit)",
            "Cycle spend \(spent) of \(limit)"))
        return lines
    }

    private func refreshProfileMetadata() {
        guard !isRefreshingUsage else { return }   // evita ciclos concorrentes (timer + refresh manual)
        isRefreshingUsage = true
        refreshPreferences()                        // reflete o estado de "carregando" imediatamente
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        let shouldRefreshCursor = CursorMonitoring.isEnabled()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var weeklyCreditsHits: [WeeklyCreditsAlertHit] = []
            for profile in profiles {
                guard let status = try? self.auth.status(profileDirectory: profile.directory) else { continue }
                // `update` mescla no registro atual: este ciclo pode levar dezenas de segundos
                // (CLI + rede por perfil) e `save(profile)` reverteria um rename/ativação feito
                // nesse meio-tempo com o snapshot velho de `profiles`.
                var updated = (try? self.store.update(id: profile.id) { current in
                    current.email = status.email ?? current.email
                    current.organization = status.organization ?? current.organization
                    current.kind = status.kind
                    current.health = status.isAuthenticated ? .ready : .expired
                }) ?? profile
                if let snapshot = try? await self.usage.fetch(profileDirectory: profile.directory) {
                    var snapshot = snapshot
                    snapshot = ClaudeUsageSnapshot(fetchedAt: snapshot.fetchedAt, plan: snapshot.plan, quotas: snapshot.quotas, source: snapshot.source, tokens: self.usage.tokenUsage(profileDirectory: profile.directory))
                    updated.usage = snapshot
                    updated = (try? self.store.update(id: profile.id) { $0.usage = snapshot }) ?? updated
                    if updated.id == activeID {
                        let active = updated; let snap = snapshot
                        await MainActor.run { self.checkFiveHourAlert(profile: active, snapshot: snap) }
                    }
                    let current = updated; let snap = snapshot
                    if let hit = await MainActor.run(body: { self.checkWeeklyCreditsAlert(profile: current, snapshot: snap) }) {
                        weeklyCreditsHits.append(hit)
                    }
                }
            }
            if !weeklyCreditsHits.isEmpty {
                let hits = weeklyCreditsHits
                await MainActor.run { self.notifyWeeklyCreditsAlert(hits) }
            }
            if shouldRefreshCursor {
                await self.refreshCursorUsage()
            }
            await MainActor.run { self.isRefreshingUsage = false; self.rebuildMenu(); self.refreshPreferences() }
        }
    }

    private func refreshCursorUsage() async {
        do {
            let snapshot = try await cursorUsage.fetch()
            try? cursorUsageStore.save(snapshot)
            await MainActor.run {
                self.cursorSnapshot = snapshot
                self.checkCursorBudgetAlert(snapshot)
            }
        } catch let error as CursorUsageError where error == .unauthorized || error == .tokenExpired {
            await MainActor.run { self.cursorCredentials.invalidate() }
        } catch {
            // Degradação: mantém o último snapshot em cache; não interrompe o fluxo Claude.
        }
    }

    private func checkCursorBudgetAlert(_ snapshot: CursorUsageSnapshot) {
        guard let plan = snapshot.planUsage,
              let percent = plan.dashboardUsedPercent else { return }
        let threshold = CursorBudgetAlertThreshold.resolve(
            UserDefaults.standard.double(forKey: CursorBudgetAlertThreshold.defaultsKey))
        guard cursorBudgetAlert.evaluate(
            usedPercent: percent,
            threshold: threshold,
            billingCycleEnd: plan.billingCycleEnd) else { return }
        let pct = Int(percent.rounded())
        let thr = Int(threshold.rounded())
        let cursorBar = plan.cursorModelsPercent.map { Int($0.rounded()) }.map { "\($0)%" } ?? "—"
        let otherBar = plan.otherModelsPercent.map { Int($0.rounded()) }.map { "\($0)%" } ?? "—"
        let message = AppStrings.t(
            "⚠️ Cursor: cota incluída em \(pct)% (Modelos Cursor \(cursorBar), Outros \(otherBar), limiar \(thr)%) — renova \(QuotaFormatter.resetDescription(plan.billingCycleEnd))",
            "⚠️ Cursor: included quota at \(pct)% (Cursor Models \(cursorBar), Other \(otherBar), threshold \(thr)%) — resets \(QuotaFormatter.resetDescription(plan.billingCycleEnd))")
        let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message
        n.soundName = fiveHourAlertSoundName()
        NSUserNotificationCenter.default.deliver(n)
    }

    private struct WeeklyCreditsAlertHit {
        let profileName: String
        let availablePercent: Int
        let resetAt: Date?
    }

    /// Fires once per profile per weekly renewal, when that profile is within 24h of its
    /// "Semanal" reset and still has at least the configured percentage of credits available.
    /// Runs for every profile, not just the active one, so idle accounts with spare credits
    /// are surfaced too.
    private func checkWeeklyCreditsAlert(profile: Profile, snapshot: ClaudeUsageSnapshot) -> WeeklyCreditsAlertHit? {
        guard let quota = snapshot.quotas.first(where: { $0.kind == .sevenDay }) else { return nil }
        let threshold = WeeklyCreditsAlertThreshold.resolve(UserDefaults.standard.double(forKey: WeeklyCreditsAlertThreshold.defaultsKey))
        guard weeklyCreditsAlert.evaluate(profileID: profile.id, usedPercent: quota.usedPercent, resetAt: quota.resetAt, availableThreshold: threshold) else { return nil }
        return WeeklyCreditsAlertHit(profileName: profile.name, availablePercent: Int((100 - quota.usedPercent).rounded()), resetAt: quota.resetAt)
    }

    private func notifyWeeklyCreditsAlert(_ hits: [WeeklyCreditsAlertHit]) {
        let message: String
        if hits.count == 1, let hit = hits.first {
            let resetPart = hit.resetAt.map { resetDescription($0) } ?? AppStrings.t("em breve", "soon")
            message = AppStrings.t(
                "💳 \(hit.profileName) ainda tem \(hit.availablePercent)% dos créditos semanais — renova \(resetPart)",
                "💳 \(hit.profileName) still has \(hit.availablePercent)% of weekly credits — renews \(resetPart)")
        } else {
            let list = hits.map { "\($0.profileName) (\($0.availablePercent)%)" }.joined(separator: ", ")
            message = AppStrings.t(
                "💳 Créditos semanais disponíveis: \(list) — aproveite antes da renovação",
                "💳 Weekly credits available: \(list) — use them before renewal")
        }
        let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message
        n.soundName = fiveHourAlertSoundName()
        NSUserNotificationCenter.default.deliver(n)
    }

    /// Fires a native alert once when the active account crosses the configured 5-hour usage
    /// threshold, telling the user when the window frees up so they know how long to wait.
    private func checkFiveHourAlert(profile: Profile, snapshot: ClaudeUsageSnapshot) {
        guard let quota = snapshot.quotas.first(where: { $0.kind == .fiveHour }) else { return }
        let threshold = FiveHourAlertThreshold.resolve(UserDefaults.standard.double(forKey: FiveHourAlertThreshold.defaultsKey))
        guard fiveHourAlert.evaluate(usedPercent: quota.usedPercent, threshold: threshold) else { return }
        notifyFiveHourAlert(profile: profile, percent: quota.usedPercent, threshold: threshold, resetAt: quota.resetAt)
    }

    private func notifyFiveHourAlert(profile: Profile, percent: Double, threshold: Double, resetAt: Date?) {
        let pct = Int(percent.rounded()); let thr = Int(threshold.rounded())
        var message = AppStrings.t(
            "⚠️ Troque de conta: \(profile.name) está em \(pct)% da janela de 5h (limite \(thr)%)",
            "⚠️ Switch accounts: \(profile.name) is at \(pct)% of the 5-hour window (threshold \(thr)%)")
        if let resetAt {
            message += AppStrings.t(" — a janela de 5h libera \(resetDescription(resetAt))",
                                    " — the 5-hour window frees up \(resetDescription(resetAt))")
        }
        let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message
        n.soundName = fiveHourAlertSoundName()
        NSUserNotificationCenter.default.deliver(n)
    }

    /// "às HH:MM" when the reset is later today, otherwise "em dd/MM às HH:MM".
    private func resetDescription(_ date: Date) -> String { QuotaFormatter.resetDescription(date) }

    private func fiveHourAlertSoundName() -> String? {
        switch FiveHourAlertSound(defaultsValue: UserDefaults.standard.string(forKey: FiveHourAlertSound.defaultsKey)) {
        case .none: return nil
        case .standard: return NSUserNotificationDefaultSoundName
        case .basso: return "Basso"
        case .glass: return "Glass"
        case .hero: return "Hero"
        case .ping: return "Ping"
        case .sosumi: return "Sosumi"
        }
    }

    private func usageTooltip(for profile: Profile) -> String {
        guard let usage = profile.usage, !usage.quotas.isEmpty else {
            return "Uso indisponível — faça login novamente nesta conta para consultar as cotas."
        }
        let lines = usage.quotas.map { quota in
            let reset = quota.resetAt.map { "renova \(resetDescription($0))" } ?? "renovação indisponível"
            return "\(quota.key): \(Int(quota.usedPercent.rounded()))% usado (\(reset))"
        }
        return ([usage.plan ?? "Claude Pro/Max"] + lines + ["Fonte: Claude Code OAuth"]).joined(separator: "\n")
    }

    private func usageSummary(for profile: Profile) -> String {
        guard let usage = profile.usage else { return "    Uso: indisponível — refaça o login" }
        let quotas = usage.quotas.map { "\($0.key): \(Int($0.usedPercent.rounded()))%" }.joined(separator: "  •  ")
        let tokens = usage.tokens.map { "Tokens: \($0.total.formatted())" } ?? "Tokens: —"
        return "    \(quotas)  •  \(tokens)"
    }

    /// A separate visible line in the dropdown spelling out each window's reset time, so it is
    /// clear that the 5-hour window and the weekly window free up at different moments.
    private func renewalSummary(for profile: Profile) -> String? {
        guard let usage = profile.usage else { return nil }
        let parts = usage.quotas.compactMap { quota -> String? in
            guard let resetAt = quota.resetAt else { return nil }
            return "\(quota.key) \(resetDescription(resetAt))"
        }
        guard !parts.isEmpty else { return nil }
        return "    " + AppStrings.t("Renova", "Resets") + " — " + parts.joined(separator: "  •  ")
    }

    private func activateFromPreferences(_ profile: Profile) {
        Task {
            do { let result = try await activation.activate(profile, syncDesktopApp: relaunchDesktopOnSwitch); fiveHourAlert.reset(); rebuildMenu(); refreshPreferences(); notify(activationResult: result) }
            catch { showError(error) }
        }
    }

    private func reloginFromPreferences(_ profile: Profile) {
        let alert = NSAlert(); alert.messageText = "Refazer login"; alert.informativeText = "O navegador será aberto para autenticar novamente a conta \(profile.email ?? profile.name). O nome e o perfil ativo não serão alterados."; alert.addButton(withTitle: "Continuar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify(AppStrings.t("Aguardando login de \(profile.name)…", "Waiting for \(profile.name) to sign in…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.auth.login(profileDirectory: profile.directory, kind: profile.kind)
                let status = try self.auth.status(profileDirectory: profile.directory)
                let updated = try self.store.update(id: profile.id) { current in
                    current.email = status.email ?? current.email
                    current.organization = status.organization ?? current.organization
                    current.kind = status.kind
                    current.health = status.isAuthenticated ? .ready : .expired
                }
                DispatchQueue.main.async { self.rebuildMenu(); self.refreshPreferences(); self.notify(AppStrings.t("Login atualizado: \(updated.email ?? updated.name)", "Login updated: \(updated.email ?? updated.name)")) }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    private func removeFromPreferences(_ profile: Profile) {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        if profile.id == activeID && profiles.count == 1 {
            showError(NSError(domain: "Claude Account Switcher", code: 4, userInfo: [NSLocalizedDescriptionKey: "Adicione outra conta antes de remover a única conta ativa."]))
            return
        }

        let alert = NSAlert(); alert.messageText = AppStrings.t("Remover perfil?", "Remove profile?"); alert.informativeText = AppStrings.t("A conta \(profile.name), suas sessões e a credencial correspondente no Keychain serão apagadas deste Mac. Esta ação não remove a conta na Anthropic.", "The account \(profile.name), its sessions and the matching Keychain credential will be deleted from this Mac. This does not remove the account at Anthropic."); alert.addButton(withTitle: AppStrings.t("Remover", "Remove")); alert.addButton(withTitle: AppStrings.t("Cancelar", "Cancel")); alert.alertStyle = .warning
        // Remover apaga o diretório onde sessões abertas gravam transcript e `.claude.json`:
        // elas falhariam no meio ou recriariam arquivos soltos. Avisa para fechá-las antes.
        let running = SessionActivity.runningSessions(in: profile.directory)
        if !running.isEmpty {
            let pids = running.map { String($0.pid) }.joined(separator: ", ")
            alert.informativeText += "\n\n" + AppStrings.t(
                "⚠️ \(running.count) sessão(ões) do Claude Code ainda em execução neste perfil (pid \(pids)). Elas perderão acesso ao próprio diretório e podem corromper arquivos ao gravar. Feche-as antes de remover.",
                "⚠️ \(running.count) Claude Code session(s) still running in this profile (pid \(pids)). They will lose their directory and may corrupt files on write. Close them before removing.")
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                if profile.id == activeID, let replacement = profiles.first(where: { $0.id != profile.id }) {
                    _ = try await activation.activate(replacement, syncDesktopApp: relaunchDesktopOnSwitch); fiveHourAlert.reset()
                }
                try store.remove(profile)
                // Best-effort: o diretório já foi embora; um item de Keychain que sobrar não é
                // motivo para falhar a remoção (a manutenção lista órfãos depois).
                try? keychain.delete(for: profile.directory)
                rebuildMenu(); refreshPreferences(); notify(AppStrings.t("Perfil removido", "Profile removed"))
            } catch { showError(error) }
        }
    }

    private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Desinstalar Claude Account Switcher?"
        alert.informativeText = "O aplicativo, o launcher e a integração do terminal serão removidos. Seus perfis, credenciais e dados em Library/Application Support serão preservados."
        alert.addButton(withTitle: "Desinstalar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            try shell.remove(home: home)
            try? loginItem.setEnabled(false)
            try? FileManager.default.removeItem(at: shell.launcherURL())
            let bundle = Bundle.main.bundleURL
            if bundle.path.hasPrefix("/Applications/") || bundle.path.hasPrefix(home.appendingPathComponent("Applications").path + "/") {
                try? FileManager.default.removeItem(at: bundle)
            }
            preferencesWindowController?.close()
            notify(AppStrings.t("Aplicativo desinstalado; seus perfis foram preservados", "App uninstalled; your profiles were preserved"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } catch { showError(error) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func notify(_ message: String) { let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message; NSUserNotificationCenter.default.deliver(n) }
    private func notify(activationResult result: ActivationResult) {
        switch result.desktopSync {
        case .synced:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name) (app nativo reaberto)", "Active profile: \(result.profile.name) (native app reopened)"))
        case .skipped:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name)", "Active profile: \(result.profile.name)"))
        case .failed:
            notify(AppStrings.t("Perfil ativo: \(result.profile.name) — não consegui reabrir o app nativo, abra manualmente", "Active profile: \(result.profile.name) — could not reopen the native app, open it manually"))
        }
    }
    private func showError(_ error: Error) { let alert = NSAlert(error: NSError(domain: "Claude Account Switcher", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])); alert.runModal() }

    private func installShortcutMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.option, .command]), event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
    }
}
