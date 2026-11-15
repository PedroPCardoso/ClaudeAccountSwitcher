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
    private var isComputing = false
    private var generation = 0
    private var selectedIDs: Set<UUID> = []
    private var series: [DailyTokenUsage] = []
    private var recommendation = PlanRecommendation(verdict: .inconclusive, rationale: "")
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
        // Início de ciclo (`isRefreshing == true`): os logs ainda não mudaram, só o spinner.
        // Recalcular a série aqui era trabalho jogado fora (o fim do ciclo recalcula).
        if isRefreshing { render() } else { recompute() }
    }

    private func toggle(_ id: UUID) {
        var current = Set(AppPreferences.analysisSelectedProfiles(from: allProfiles).map(\.id))
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        AppPreferences.setAnalysisSelection(Array(current))
        recompute()
    }

    /// Lê/agrega os `.jsonl` FORA da main thread (a primeira leitura fria percorre centenas de MB e
    /// travava a UI) e só aplica o resultado se nenhum recompute mais novo foi pedido nesse meio-tempo.
    private func recompute() {
        let selected = AppPreferences.analysisSelectedProfiles(from: allProfiles)
        selectedIDs = Set(selected.map(\.id))
        generation += 1
        let current = generation
        isComputing = true
        render()
        let history = self.history
        Task.detached(priority: .utility) { [weak self] in
            let series = history.dailyUsage(profiles: selected, now: .now)
            let recommendation = PlanRecommendation.evaluate(series: series, selectedProfileCount: selected.count)
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.series = series
                self.recommendation = recommendation
                self.isComputing = false
                self.render()
            }
        }
    }

    private func render() {
        hostingView.rootView = AnalysisView(
            profiles: allProfiles,
            selectedIDs: selectedIDs,
            series: series,
            recommendation: recommendation,
            isRefreshing: isRefreshing || isComputing,
            onToggle: { [weak self] in self?.toggle($0) },
            onRefresh: onRefresh)
    }
}
