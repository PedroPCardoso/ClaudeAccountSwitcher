import SwiftUI
import Charts
import ClaudeAccountSwitcherCore

struct CursorAnalysisView: View {
    let snapshot: CursorUsageSnapshot?
    let selectedFamilies: Set<CursorModelFamily>
    var isRefreshing: Bool = false
    var onToggle: (CursorModelFamily) -> Void = { _ in }
    var onRefresh: () -> Void = {}

    private var filteredDaily: [CursorDailySpend] {
        guard let snapshot else { return [] }
        return snapshot.daily.filter { selectedFamilies.contains(CursorModelFamily.classify($0.modelIntent)) }
    }

    private var modelsInSelection: [String] {
        Array(Set(filteredDaily.map(\.modelIntent))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                chartSection.frame(maxWidth: .infinity, alignment: .leading)
                familySelector.frame(width: 200)
            }
            footer
            Text(AppStrings.t(
                "Histórico diário do ciclo atual, agrupado por modelo. Custos vêm da API do Cursor (já calculados), não de uma tabela local.",
                "Daily history for the current cycle, grouped by model. Costs come from the Cursor API (already calculated), not a local price table."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.t("Análise de uso — Cursor", "Usage analysis — Cursor")).font(.title2.weight(.semibold))
                Text(AppStrings.t(
                    "Gasto diário por modelo no ciclo de faturamento atual.",
                    "Daily spend by model in the current billing cycle."))
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

    @ViewBuilder
    private var chartSection: some View {
        if snapshot?.planUsage == nil {
            emptyState(
                AppStrings.t("Sem dados do Cursor", "No Cursor data"),
                AppStrings.t("Faça login no Cursor e atualize.", "Sign in to Cursor and refresh."))
        } else if filteredDaily.isEmpty {
            emptyState(
                AppStrings.t("Sem histórico no período", "No history in this period"),
                AppStrings.t("Selecione famílias de modelo à direita, ou aguarde uso no ciclo.",
                             "Select model families on the right, or wait for usage in the cycle."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppStrings.t("Gasto por dia (empilhado por modelo)", "Spend per day (stacked by model)"))
                    .font(.subheadline.weight(.medium))
                Chart {
                    ForEach(filteredDaily, id: \.self) { row in
                        BarMark(
                            x: .value(AppStrings.t("Dia", "Day"), row.day, unit: .day),
                            y: .value(AppStrings.t("USD", "USD"), row.spendCents / 100))
                            .foregroundStyle(by: .value(AppStrings.t("Modelo", "Model"), row.modelIntent))
                    }
                }
                .frame(minHeight: 260)
            }
        }
    }

    private var familySelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.t("Famílias", "Families")).font(.subheadline.weight(.medium))
            ForEach(CursorModelFamily.allCases, id: \.self) { family in
                Toggle(isOn: Binding(
                    get: { selectedFamilies.contains(family) },
                    set: { _ in onToggle(family) }
                )) {
                    Text(familyLabel(family)).font(.caption)
                }
                .toggleStyle(.checkbox)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        Group {
            if let plan = snapshot?.planUsage {
                let totalSpend = filteredDaily.reduce(0.0) { $0 + $1.spendCents }
                let totalTokens = filteredDaily.reduce(0) { $0 + $1.totalTokens }
                Text(AppStrings.t(
                    "Seleção: \(formatUSD(totalSpend)) · \(totalTokens.formatted()) tokens · ciclo \(formatUSD(plan.totalSpendCents)) de \(formatUSD(plan.limitCents))",
                    "Selection: \(formatUSD(totalSpend)) · \(totalTokens.formatted()) tokens · cycle \(formatUSD(plan.totalSpendCents)) of \(formatUSD(plan.limitCents))"))
                    .font(.caption).foregroundStyle(.secondary)
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

    private func familyLabel(_ family: CursorModelFamily) -> String {
        switch family {
        case .claude: return "Claude"
        case .gpt: return "GPT / OpenAI"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .composer: return "Composer / Auto"
        case .other: return AppStrings.t("Outros", "Other")
        }
    }

    private func formatUSD(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }
}
