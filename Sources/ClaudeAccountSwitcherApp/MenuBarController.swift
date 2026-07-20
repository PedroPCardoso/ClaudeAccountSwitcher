import AppKit
import ClaudeAccountSwitcherCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Any?
    private let store: ProfileStore
    private let activation: ActivationService
    private let auth: ClaudeAuthService
    private let usage = ClaudeUsageService()
    private let migration: MigrationService
    private let shell: ShellIntegrationManager
    private let locator: ClaudeLocator
    private let loginItem = LoginItemService()
    private var preferencesWindowController: PreferencesWindowController?
    private var usageWindowController: UsageWindowController?
    private var usageRefreshTimer: Timer?

    override init() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude Account Switcher", isDirectory: true)
        store = try! ProfileStore(root: root)
        let locator = ClaudeLocator()
        self.locator = locator
        auth = ClaudeAuthService(locator: locator)
        shell = ShellIntegrationManager(appSupport: root)
        migration = MigrationService(store: store)
        activation = ActivationService(store: store)
        super.init()
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
        if let official = try? locator.locate() { try? shell.install(home: FileManager.default.homeDirectoryForCurrentUser, officialBinary: official) }
        if let active = try? store.active() { try? SystemLaunchdEnvironment().set(active.directory.path) }
        try? loginItem.setEnabled(true)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let profiles = (try? store.list()) ?? []
        let active = try? store.active()?.id
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
            }
        }
        menu.addItem(.separator())
        let usageItem = NSMenuItem(title: AppStrings.t("Ver uso no Claude…", "View Claude usage…"), action: #selector(openUsage), keyEquivalent: "")
        usageItem.target = self
        usageItem.toolTip = "Abre o painel visual com uso e tokens de todas as contas"
        menu.addItem(usageItem)
        menu.addItem(withTitle: AppStrings.t("Preferências…", "Preferences…"), action: #selector(preferences), keyEquivalent: ","); menu.items.last?.target = self
        menu.addItem(withTitle: AppStrings.t("Sair", "Quit"), action: #selector(quit), keyEquivalent: "q"); menu.items.last?.target = self
        statusItem.menu = menu
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        Task { do { let result = try await activation.activate(profile); rebuildMenu(); notify(activationResult: result) } catch { showError(error) } }
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
                DispatchQueue.main.async { self.rebuildMenu(); self.notify("Conta adicionada") }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let id = UUID(); let destination = try store.createManagedDirectory(id: id)
            let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for entry in entries { try FileManager.default.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent)) }
            try store.save(Profile(id: id, name: source.lastPathComponent, kind: .custom, directory: destination, health: .unknown)); rebuildMenu(); notify("Perfil importado")
        } catch { showError(error) }
    }

    @objc private func renameProfile() {
        let profiles = (try? store.list()) ?? []
        guard !profiles.isEmpty else { notify("Nenhum perfil cadastrado"); return }
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
        var updated = profile; updated.name = name
        do { try store.save(updated); rebuildMenu(); refreshPreferences(); notify("Perfil renomeado") } catch { showError(error) }
    }

    @objc private func openUsage() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        if usageWindowController == nil { usageWindowController = UsageWindowController(profiles: profiles, activeID: activeID) }
        else { usageWindowController?.update(profiles: profiles, activeID: activeID) }
        usageWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    @objc private func migrateExisting() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let plan = try migration.preview(home: home)
            guard !plan.sources.isEmpty else { notify("Nenhum perfil existente encontrado"); return }
            let alert = NSAlert(); alert.messageText = "Migrar perfis existentes?"; alert.informativeText = plan.sources.map(\.path).joined(separator: "\n") + "\n\nOs originais serão mantidos."; alert.addButton(withTitle: "Migrar"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let report = try migration.execute(plan)
            rebuildMenu(); notify("\(report.imported.count) perfil(is) migrado(s)")
        } catch { showError(error) }
    }

    @objc private func preferences() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                profiles: profiles,
                activeID: activeID,
                onActivate: { [weak self] profile in self?.activateFromPreferences(profile) },
                onRelogin: { [weak self] profile in self?.reloginFromPreferences(profile) },
                onRename: { [weak self] profile in self?.renameSpecificProfile(profile) },
                onRemove: { [weak self] profile in self?.removeFromPreferences(profile) },
                onUninstall: { [weak self] in self?.uninstall() },
                onAdd: { [weak self] in self?.addAccount() },
                onImport: { [weak self] in self?.importProfile() },
                onMigrate: { [weak self] in self?.migrateExisting() }
            )
        } else {
            preferencesWindowController?.update(profiles: profiles, activeID: activeID)
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshProfileMetadata()
    }

    private func refreshPreferences() {
        let profiles = (try? store.list()) ?? []
        let activeID = try? store.active()?.id
        preferencesWindowController?.update(profiles: profiles, activeID: activeID)
        usageWindowController?.update(profiles: profiles, activeID: activeID)
    }

    private func refreshProfileMetadata() {
        let profiles = (try? store.list()) ?? []
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for profile in profiles {
                guard let status = try? self.auth.status(profileDirectory: profile.directory) else { continue }
                var updated = profile
                updated.email = status.email ?? profile.email
                updated.organization = status.organization ?? profile.organization
                updated.kind = status.kind
                updated.health = status.isAuthenticated ? .ready : .expired
                try? self.store.save(updated)
                if let snapshot = try? await self.usage.fetch(profileDirectory: profile.directory) {
                    var snapshot = snapshot
                    snapshot = ClaudeUsageSnapshot(fetchedAt: snapshot.fetchedAt, plan: snapshot.plan, quotas: snapshot.quotas, source: snapshot.source, tokens: self.usage.tokenUsage(profileDirectory: profile.directory))
                    updated.usage = snapshot
                    try? self.store.save(updated)
                }
            }
            await MainActor.run { self.rebuildMenu(); self.refreshPreferences() }
        }
    }

    private func usageTooltip(for profile: Profile) -> String {
        guard let usage = profile.usage, !usage.quotas.isEmpty else {
            return "Uso indisponível — faça login novamente nesta conta para consultar as cotas."
        }
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        let lines = usage.quotas.map { quota in
            let reset = quota.resetAt.map { "renova às \(formatter.string(from: $0))" } ?? "renovação indisponível"
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

    private func activateFromPreferences(_ profile: Profile) {
        Task {
            do { let result = try await activation.activate(profile); rebuildMenu(); refreshPreferences(); notify(activationResult: result) }
            catch { showError(error) }
        }
    }

    private func reloginFromPreferences(_ profile: Profile) {
        let alert = NSAlert(); alert.messageText = "Refazer login"; alert.informativeText = "O navegador será aberto para autenticar novamente a conta \(profile.email ?? profile.name). O nome e o perfil ativo não serão alterados."; alert.addButton(withTitle: "Continuar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Aguardando login de \(profile.name)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.auth.login(profileDirectory: profile.directory, kind: profile.kind)
                let status = try self.auth.status(profileDirectory: profile.directory)
                var updated = profile
                updated.email = status.email ?? profile.email
                updated.organization = status.organization ?? profile.organization
                updated.kind = status.kind
                updated.health = status.isAuthenticated ? .ready : .expired
                try self.store.save(updated)
                DispatchQueue.main.async { self.rebuildMenu(); self.refreshPreferences(); self.notify("Login atualizado: \(updated.email ?? updated.name)") }
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

        let alert = NSAlert(); alert.messageText = "Remover perfil?"; alert.informativeText = "A conta \(profile.name) e suas credenciais isoladas serão apagadas deste Mac. Esta ação não remove a conta na Anthropic."; alert.addButton(withTitle: "Remover"); alert.addButton(withTitle: "Cancelar"); alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                if profile.id == activeID, let replacement = profiles.first(where: { $0.id != profile.id }) {
                    _ = try await activation.activate(replacement)
                }
                try store.remove(profile)
                rebuildMenu(); refreshPreferences(); notify("Perfil removido")
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
            notify("Aplicativo desinstalado; seus perfis foram preservados")
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
