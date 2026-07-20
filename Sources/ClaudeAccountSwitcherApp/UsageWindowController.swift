import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class UsageWindowController: NSWindowController {
    private let hostingView: NSHostingView<UsageView>

    init(profiles: [Profile], activeID: UUID?) {
        hostingView = NSHostingView(rootView: UsageView(profiles: profiles, activeID: activeID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Uso do Claude — Claude Account Switcher"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [Profile], activeID: UUID?) {
        hostingView.rootView = UsageView(profiles: profiles, activeID: activeID)
    }
}
