import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let hostingView: NSHostingView<PreferencesView>
    private let onActivate: (Profile) -> Void
    private let onRelogin: (Profile) -> Void
    private let onRename: (Profile) -> Void
    private let onRemove: (Profile) -> Void
    private let onUninstall: () -> Void
    private let onAdd: () -> Void
    private let onImport: () -> Void
    private let onMigrate: () -> Void

    init(profiles: [Profile], activeID: UUID?, onActivate: @escaping (Profile) -> Void, onRelogin: @escaping (Profile) -> Void, onRename: @escaping (Profile) -> Void, onRemove: @escaping (Profile) -> Void, onUninstall: @escaping () -> Void, onAdd: @escaping () -> Void, onImport: @escaping () -> Void, onMigrate: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onRelogin = onRelogin
        self.onRename = onRename
        self.onRemove = onRemove
        self.onUninstall = onUninstall
        self.onAdd = onAdd; self.onImport = onImport; self.onMigrate = onMigrate
        let view = PreferencesView(profiles: profiles, activeID: activeID, onActivate: onActivate, onRelogin: onRelogin, onRename: onRename, onRemove: onRemove, onUninstall: onUninstall, onAdd: onAdd, onImport: onImport, onMigrate: onMigrate)
        hostingView = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Preferências — Claude Account Switcher"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [Profile], activeID: UUID?) {
        hostingView.rootView = PreferencesView(profiles: profiles, activeID: activeID, onActivate: onActivate, onRelogin: onRelogin, onRename: onRename, onRemove: onRemove, onUninstall: onUninstall, onAdd: onAdd, onImport: onImport, onMigrate: onMigrate)
    }
}
