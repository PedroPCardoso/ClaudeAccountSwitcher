import AppKit
import SwiftUI
import ClaudeAccountSwitcherCore

@MainActor
final class AnalysisWindowController: NSWindowController {
    private let hostingView: NSHostingView<AnalysisView>
    // Uma única instância de longa vida para reaproveitar o cache por (mtime, tamanho) entre
    // recomputes (toggles, refreshes) em vez de reprocessar todos os .jsonl a cada mudança.
    private let history = UsageHistoryService()
    private var allProfiles: [Profile]
    private var isRefreshing: Bool
    private let onRefresh: () -> Void

    init(profiles: [Profile], isRefreshing: Bool = false, onRefresh: @escaping () -> Void = {}) {
        self.allProfiles = profiles
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        hostingView = NSHostingView(rootView: AnalysisView(profiles: [], selectedIDs: [], series: [], recommendation: PlanRecommendation(verdict: .inconclusive, rationale: "")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppStrings.t("Análise de uso — Claude Account Switcher", "Usage analysis — Claude Account Switcher")
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        recompute()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(profiles: [Profile], isRefreshing: Bool = false) {
        self.allProfiles = profiles
        self.isRefreshing = isRefreshing
        recompute()
    }

    private func toggle(_ id: UUID) {
        var current = Set(AppPreferences.analysisSelectedProfiles(from: allProfiles).map(\.id))
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        AppPreferences.setAnalysisSelection(Array(current))
        recompute()
    }

    private func recompute() {
        let selected = AppPreferences.analysisSelectedProfiles(from: allProfiles)
        let selectedIDs = Set(selected.map(\.id))
        let series = history.dailyUsage(profiles: selected, now: .now)
        let recommendation = PlanRecommendation.evaluate(series: series, selectedProfileCount: selected.count)
        hostingView.rootView = AnalysisView(
            profiles: allProfiles,
            selectedIDs: selectedIDs,
            series: series,
            recommendation: recommendation,
            isRefreshing: isRefreshing,
            onToggle: { [weak self] in self?.toggle($0) },
            onRefresh: onRefresh)
    }
}
