import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class CursorAnalysisWindowController: NSWindowController {
    private let hostingView: NSHostingView<CursorAnalysisView>
    private var snapshot: CursorUsageSnapshot?
    private var selectedFamilies: Set<CursorModelFamily>
    private var isRefreshing: Bool
    private let onRefresh: () -> Void

    init(snapshot: CursorUsageSnapshot?, isRefreshing: Bool = false, onRefresh: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.selectedFamilies = Set(CursorModelFamily.allCases)
        hostingView = NSHostingView(rootView: CursorAnalysisView(
            snapshot: snapshot,
            selectedFamilies: Set(CursorModelFamily.allCases),
            isRefreshing: isRefreshing,
            onToggle: { _ in },
            onRefresh: onRefresh))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppStrings.t("Análise de uso — Cursor", "Usage analysis — Cursor")
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        recompute()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(snapshot: CursorUsageSnapshot?, isRefreshing: Bool = false) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        recompute()
    }

    private func toggle(_ family: CursorModelFamily) {
        if selectedFamilies.contains(family) { selectedFamilies.remove(family) }
        else { selectedFamilies.insert(family) }
        recompute()
    }

    private func recompute() {
        hostingView.rootView = CursorAnalysisView(
            snapshot: snapshot,
            selectedFamilies: selectedFamilies,
            isRefreshing: isRefreshing,
            onToggle: { [weak self] in self?.toggle($0) },
            onRefresh: onRefresh)
    }
}
