import SwiftUI
import ClaudeAccountSwitcherCore

struct CursorUsageView: View {
    let snapshot: CursorUsageSnapshot?
    var isRefreshing: Bool = false
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppStrings.t("Uso do Cursor", "Cursor Usage")).font(.title2.weight(.semibold))
                    Text(AppStrings.t(
                        "Custo, limite e tokens por modelo da conta logada no Cursor IDE.",
                        "Cost, limit and per-model tokens for the account signed into Cursor IDE."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Button(action: onRefresh) {
                        Label(AppStrings.t("Atualizar", "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }

            if let snapshot, let plan = snapshot.planUsage {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        planCard(snapshot: snapshot, plan: plan)
                        familySummary(snapshot)
                        modelsSection(snapshot.models)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(AppStrings.t("Uso do Cursor indisponível", "Cursor usage unavailable")).font(.headline)
                    Text(AppStrings.t(
                        "Faça login no Cursor IDE e mantenha o monitoramento ativado em Preferências.",
                        "Sign in to Cursor IDE and keep monitoring enabled in Preferences."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(AppStrings.t(
                "Os dados vêm da API interna do Cursor (não documentada) e podem mudar. Valores monetários em USD do ciclo atual.",
                "Data comes from Cursor's internal (undocumented) API and may change. Monetary values are USD for the current cycle."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 720, maxWidth: .infinity, minHeight: 400, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder
    private func planCard(snapshot: CursorUsageSnapshot, plan: CursorPlanUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "laptopcomputer").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(snapshot.email ?? AppStrings.t("Conta Cursor", "Cursor account")).font(.headline)
                        if let planName = snapshot.plan {
                            Text(planName.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                        }
                    }
                    let time = snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
                    Text(AppStrings.t("Atualizado \(time)", "Updated \(time)")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Duas barras iguais à seção "Included in Pro" do Cursor — não o spend÷limit.
            if let cursorModels = plan.cursorModelsPercent {
                percentBar(
                    title: AppStrings.t("Modelos Cursor", "Cursor Models"),
                    percent: cursorModels,
                    detail: AppStrings.t(
                        "Inclui Cursor Grok 4.5 e Composer 2.5. Uso além do limite consome a cota de Outros modelos ou gasto sob demanda.",
                        "Includes Cursor Grok 4.5 and Composer 2.5. Usage beyond the limit consumes the Other Models quota or on-demand spend."))
            }

            if let otherModels = plan.otherModelsPercent {
                percentBar(
                    title: AppStrings.t("Outros modelos", "Other Models"),
                    percent: otherModels,
                    detail: AppStrings.t(
                        "Uso além do limite consome gasto sob demanda. O plano inclui pelo menos \(formatUSD(plan.limitCents)) de uso de API.",
                        "Usage beyond the limit consumes on-demand spend. Your plan includes at least \(formatUSD(plan.limitCents)) of API usage."))
            }

            Text(AppStrings.t(
                "Gasto do ciclo \(formatUSD(plan.totalSpendCents)) de \(formatUSD(plan.limitCents)) · restam \(formatUSD(plan.remainingCents))",
                "Cycle spend \(formatUSD(plan.totalSpendCents)) of \(formatUSD(plan.limitCents)) · \(formatUSD(plan.remainingCents)) remaining"))
                .font(.caption).foregroundStyle(.secondary)

            Text(AppStrings.t(
                "Renova \(QuotaFormatter.resetDescription(plan.billingCycleEnd))",
                "Resets \(QuotaFormatter.resetDescription(plan.billingCycleEnd))"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func percentBar(title: String, percent: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(AppStrings.t("\(Int(percent.rounded()))% usado", "\(Int(percent.rounded()))% used"))
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(percent >= 90 ? .red : percent >= 70 ? .orange : .blue)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func familySummary(_ snapshot: CursorUsageSnapshot) -> some View {
        let byFamily = snapshot.tokensByFamily().filter { $0.value > 0 }
        if !byFamily.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppStrings.t("Por provedor", "By provider")).font(.subheadline.weight(.medium))
                ForEach(CursorModelFamily.allCases, id: \.self) { family in
                    if let tokens = byFamily[family], tokens > 0 {
                        let cost = snapshot.costByFamily()[family] ?? 0
                        HStack {
                            Text(familyLabel(family)).font(.caption)
                            Spacer()
                            Text("\(tokens.formatted()) tokens · \(formatUSD(cost))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func modelsSection(_ models: [CursorModelUsage]) -> some View {
        if models.isEmpty {
            Text(AppStrings.t("Nenhum uso por modelo neste ciclo.", "No per-model usage in this cycle."))
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppStrings.t("Por modelo", "By model")).font(.subheadline.weight(.medium))
                ForEach(models.sorted(by: { $0.costCents > $1.costCents }), id: \.modelIntent) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.modelIntent).font(.caption.weight(.semibold))
                            Spacer()
                            Text(formatUSD(model.costCents)).font(.caption.weight(.semibold))
                        }
                        HStack(spacing: 10) {
                            Text(AppStrings.t("Entrada \(model.input.formatted())", "Input \(model.input.formatted())"))
                            Text(AppStrings.t("Saída \(model.output.formatted())", "Output \(model.output.formatted())"))
                            Text(AppStrings.t("Cache↓ \(model.cacheRead.formatted())", "Cache↓ \(model.cacheRead.formatted())"))
                            Text(AppStrings.t("Cache↑ \(model.cacheWrite.formatted())", "Cache↑ \(model.cacheWrite.formatted())"))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
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
        let dollars = cents / 100
        return String(format: "$%.2f", dollars)
    }
}
