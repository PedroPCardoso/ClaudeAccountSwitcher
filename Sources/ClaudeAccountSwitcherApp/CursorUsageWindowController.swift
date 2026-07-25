import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class CursorUsageWindowController: NSWindowController {
    private let hostingView: NSHostingView<CursorUsageView>
    private let onRefresh: () -> Void

    init(snapshot: CursorUsageSnapshot?, isRefreshing: Bool = false, onRefresh: @escaping () -> Void = {}) {
        self.onRefresh = onRefresh
        hostingView = NSHostingView(rootView: CursorUsageView(snapshot: snapshot, isRefreshing: isRefreshing, onRefresh: onRefresh))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppStrings.t("Uso do Cursor — Claude Account Switcher", "Cursor Usage — Claude Account Switcher")
        window.contentMinSize = NSSize(width: 480, height: 400)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(snapshot: CursorUsageSnapshot?, isRefreshing: Bool = false) {
        hostingView.rootView = CursorUsageView(snapshot: snapshot, isRefreshing: isRefreshing, onRefresh: onRefresh)
    }
}
