import AppKit
import ClaudeAccountSwitcherCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: Any?
    private let store: ProfileStore
    private let activation: ActivationService
    private let auth: ClaudeAuthService
    private let migration: MigrationService
    private let shell: ShellIntegrationManager
    private let locator: ClaudeLocator
    private let loginItem = LoginItemService()

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
        statusItem.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude accounts")
        installShortcutMonitor(); rebuildMenu()
        if let official = try? locator.locate() { try? shell.install(home: FileManager.default.homeDirectoryForCurrentUser, officialBinary: official) }
        if let active = try? store.active() { try? SystemLaunchdEnvironment().set(active.directory.path) }
        try? loginItem.setEnabled(true)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let profiles = (try? store.list()) ?? []
        let active = try? store.active()?.id
        if profiles.isEmpty {
            menu.addItem(withTitle: "Nenhum perfil importado", action: nil, keyEquivalent: "")
        } else {
            for profile in profiles {
                let item = NSMenuItem(title: profile.name + (profile.email.map { " — \($0)" } ?? ""), action: #selector(selectProfile(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = profile; item.state = profile.id == active ? .on : .off; menu.addItem(item)
            }
        }
        menu.addItem(.separator()); menu.addItem(withTitle: "Adicionar conta…", action: #selector(addAccount), keyEquivalent: ""); menu.items.last?.target = self
        menu.addItem(withTitle: "Importar perfil…", action: #selector(importProfile), keyEquivalent: ""); menu.items.last?.target = self
        menu.addItem(withTitle: "Renomear perfil…", action: #selector(renameProfile), keyEquivalent: ""); menu.items.last?.target = self
        menu.addItem(withTitle: "Migrar perfis atuais…", action: #selector(migrateExisting), keyEquivalent: ""); menu.items.last?.target = self
        menu.addItem(withTitle: "Preferências…", action: #selector(preferences), keyEquivalent: ","); menu.items.last?.target = self
        menu.addItem(withTitle: "Sair", action: #selector(quit), keyEquivalent: "q"); menu.items.last?.target = self
        statusItem.menu = menu
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        Task { do { _ = try await activation.activate(profile); rebuildMenu(); notify("Perfil ativo: \(profile.name)") } catch { showError(error) } }
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
        let index = picker.indexOfSelectedItem; let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profiles.indices.contains(index), !name.isEmpty else { showError(NSError(domain: "Claude Account Switcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Informe um nome para o perfil."])); return }
        var updated = profiles[index]; updated.name = name
        do { try store.save(updated); rebuildMenu(); notify("Perfil renomeado") } catch { showError(error) }
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

    @objc private func preferences() { let alert = NSAlert(); alert.messageText = "Claude Account Switcher"; alert.informativeText = "Atalho global: ⌥⌘C\nPerfis são isolados e aplicados a novas sessões.\nUse o menu para adicionar, importar ou trocar contas."; alert.addButton(withTitle: "OK"); alert.runModal() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func notify(_ message: String) { let n = NSUserNotification(); n.title = "Claude Account Switcher"; n.informativeText = message; NSUserNotificationCenter.default.deliver(n) }
    private func showError(_ error: Error) { let alert = NSAlert(error: NSError(domain: "Claude Account Switcher", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])); alert.runModal() }

    private func installShortcutMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.option, .command]), event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
    }
}
