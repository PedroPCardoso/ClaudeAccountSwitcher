import SwiftUI
import Charts
import ClaudeAccountSwitcherCore

/// Seção "Análise": tokens por dia com breakdown por conta (empilhado) + total, restrito à
/// seleção, mais a lista de contas (toggle) e o veredicto Max vs múltiplos Pro. A view é
/// stateless; o `AnalysisWindowController` recomputa série + recomendação a cada toggle e
/// re-renderiza (mesmo padrão de `UsageView`/`UsageWindowController`).
struct AnalysisView: View {
    let profiles: [Profile]
    let selectedIDs: Set<UUID>
    let series: [DailyTokenUsage]
    let recommendation: PlanRecommendation
    var isRefreshing: Bool = false
    var onToggle: (UUID) -> Void = { _ in }
    var onRefresh: () -> Void = {}

    private var selectedProfiles: [Profile] { profiles.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recommendationCard
            HStack(alignment: .top, spacing: 16) {
                chartSection.frame(maxWidth: .infinity, alignment: .leading)
                accountSelector.frame(width: 230)
            }
            Text(AppStrings.t(
                "Baseado nos tokens somados das sessões locais (.jsonl) das contas selecionadas, deduplicando chunks de streaming. A recomendação não usa preço nem limite de plano — é relativa ao seu histórico. O custo é uma estimativa por tabela de preços fixa (Opus/Sonnet/Haiku), com cache lido a ~0,1x e cache escrito a 1,25–2x do input.",
                "Based on summed tokens from the selected accounts' local sessions (.jsonl), deduplicating streaming chunks. The recommendation uses neither price nor plan limits — it is relative to your own history. Cost is an estimate from a fixed price table (Opus/Sonnet/Haiku), with cache reads at ~0.1x and cache writes at 1.25–2x of input."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.t("Análise de uso", "Usage analysis")).font(.title2.weight(.semibold))
                Text(AppStrings.t("Consumo agregado de tokens ao longo do tempo — decida 1 Max vs 2–3 Pro.",
                                  "Aggregate token usage over time — decide 1 Max vs 2–3 Pro."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if isRefreshing { ProgressView().controlSize(.small) }
                Button(action: onRefresh) { Label(AppStrings.t("Atualizar", "Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var recommendationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: verdictIcon).font(.title2).foregroundStyle(verdictColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictTitle).font(.headline)
                Text(verdictDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(verdictColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var chartSection: some View {
        if selectedProfiles.isEmpty {
            emptyState(AppStrings.t("Selecione ao menos uma conta", "Select at least one account"),
                       AppStrings.t("Marque uma conta à direita para ver o consumo agregado.",
                                    "Check an account on the right to see aggregate usage."))
        } else if series.isEmpty {
            emptyState(AppStrings.t("Sem histórico de tokens", "No token history"),
                       AppStrings.t("As contas selecionadas ainda não têm sessões com uso registrado.",
                                    "The selected accounts have no sessions with recorded usage yet."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppStrings.t("Tokens por dia (empilhado por conta)", "Tokens per day (stacked by account)"))
                    .font(.subheadline.weight(.medium))
                Chart {
                    ForEach(series, id: \.day) { bucket in
                        ForEach(selectedProfiles) { profile in
                            if let tokens = bucket.perProfile[profile.id], tokens > 0 {
                                BarMark(
                                    x: .value(AppStrings.t("Dia", "Day"), bucket.day, unit: .day),
                                    y: .value(AppStrings.t("Tokens", "Tokens"), tokens))
                                    .foregroundStyle(color(for: profile))
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppStrings.t("Total agregado no período: \(totalTokens.formatted()) tokens · custo estimado ~\(formattedCost)",
                                      "Aggregate total for the period: \(totalTokens.formatted()) tokens · estimated cost ~\(formattedCost)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(cacheBreakdownLine).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accountSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.t("Contas na análise", "Accounts in the analysis")).font(.subheadline.weight(.medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profiles) { profile in
                        Button { onToggle(profile.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIDs.contains(profile.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedIDs.contains(profile.id) ? color(for: profile) : .secondary)
                                Circle().fill(color(for: profile)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name).font(.subheadline)
                                    if let email = profile.email {
                                        Text(email).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var totalTokens: Int { series.reduce(0) { $0 + $1.total } }
    private var totalCostUSD: Double { series.reduce(0) { $0 + $1.totalCostUSD } }

    /// Soma a quebra por tipo de todos os dias/perfis da série, para a linha de detalhamento.
    private var aggregateBreakdown: TokenBreakdown {
        series.flatMap { $0.breakdownPerProfile.values }.reduce(.zero, +)
    }

    private var formattedCost: String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"
        f.maximumFractionDigits = totalCostUSD >= 100 ? 0 : 2
        return f.string(from: NSNumber(value: totalCostUSD)) ?? "$\(totalCostUSD)"
    }

    /// Linha "input X · output Y · cache-read Z · cache-write W" — deixa visível que a leitura de
    /// cache (barata) e a escrita de cache (cara) são coisas distintas por trás do total.
    private var cacheBreakdownLine: String {
        let b = aggregateBreakdown
        func n(_ v: Int) -> String { v.formatted() }
        return AppStrings.t(
            "input \(n(b.input)) · output \(n(b.output)) · cache lido \(n(b.cacheRead)) · cache escrito \(n(b.cacheCreation))",
            "input \(n(b.input)) · output \(n(b.output)) · cache read \(n(b.cacheRead)) · cache write \(n(b.cacheCreation))")
    }

    // MARK: - Verdict presentation (bilingual, built here from the Core verdict)

    private var verdictTitle: String {
        switch recommendation.verdict {
        case .singleMaxLikelyEnough: return AppStrings.t("1 Max provavelmente cobre", "1 Max likely covers it")
        case .multipleProJustified: return AppStrings.t("O uso justifica 2–3 Pro", "Usage justifies 2–3 Pro")
        case .inconclusive: return AppStrings.t("Inconclusivo", "Inconclusive")
        }
    }

    private var verdictDetail: String {
        switch recommendation.verdict {
        case .singleMaxLikelyEnough:
            return AppStrings.t("O consumo raramente se sobrepõe entre as contas selecionadas — uma única assinatura Max tende a bastar.",
                                "Usage rarely overlaps across the selected accounts — a single Max subscription tends to suffice.")
        case .multipleProJustified:
            return AppStrings.t("Há demanda simultânea recorrente em várias contas — manter 2–3 Pro faz sentido.",
                                "There is recurring simultaneous demand across accounts — keeping 2–3 Pro makes sense.")
        case .inconclusive:
            return AppStrings.t("Selecione contas e acumule mais dias de uso para uma recomendação confiável.",
                                "Select accounts and accumulate more days of usage for a reliable recommendation.")
        }
    }

    private var verdictIcon: String {
        switch recommendation.verdict {
        case .singleMaxLikelyEnough: return "person.crop.circle.badge.checkmark"
        case .multipleProJustified: return "person.2.circle"
        case .inconclusive: return "questionmark.circle"
        }
    }

    private var verdictColor: Color {
        switch recommendation.verdict {
        case .singleMaxLikelyEnough: return .green
        case .multipleProJustified: return .orange
        case .inconclusive: return .secondary
        }
    }

    private func color(for profile: Profile) -> Color {
        switch profile.color.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "yellow": return .yellow
        case "indigo": return .indigo
        case "gray", "grey": return .gray
        default: return .accentColor
        }
    }
}
