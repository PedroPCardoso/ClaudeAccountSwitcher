import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class UsageWindowController: NSWindowController {
    private let hostingView: NSHostingView<UsageView>
    private let onRefresh: () -> Void

    init(profiles: [Profile], activeID: UUID?, isRefreshing: Bool = false, onRefresh: @escaping () -> Void = {}) {
        self.onRefresh = onRefresh
        hostingView = NSHostingView(rootView: UsageView(profiles: profiles, activeID: activeID, isRefreshing: isRefreshing, onRefresh: onRefresh))
        // `.resizable` + tamanhos mínimos: a janela deixa de ser fixa em 720x500 e a lista
        // longa de perfis passa a rolar/expandir em vez de estourar (issue #14).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Uso do Claude — Claude Account Switcher"
        window.contentMinSize = NSSize(width: 480, height: 380)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [Profile], activeID: UUID?, isRefreshing: Bool = false) {
        hostingView.rootView = UsageView(profiles: profiles, activeID: activeID, isRefreshing: isRefreshing, onRefresh: onRefresh)
    }
}
