import SwiftUI
import ClaudeAccountSwitcherCore

struct UsageView: View {
    let profiles: [Profile]
    let activeID: UUID?
    var isRefreshing: Bool = false
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppStrings.t("Uso do Claude", "Claude Usage")).font(.title2.weight(.semibold))
                    Text(AppStrings.t("Cotas reais das contas Pro/Max autenticadas no Claude Code.", "Live quotas for authenticated Claude Pro/Max accounts."))
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
                    .help(AppStrings.t("Atualizar cotas agora", "Refresh quotas now"))
                }
            }

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(AppStrings.t("Nenhuma conta", "No accounts")).font(.headline)
                    Text(AppStrings.t("Adicione uma conta para acompanhar o uso.", "Add an account to monitor usage.")).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(profiles) { profile in usageCard(profile) }
                    }
                    .padding(.vertical, 2)
                }
            }
            Text(AppStrings.t("Os percentuais são consultados diretamente na conta selecionada. O endpoint de uso é uma interface de consumidor e pode sofrer alterações.", "Percentages are queried directly from the selected account. The usage endpoint is a consumer interface and may change."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 720, maxWidth: .infinity, minHeight: 380, idealHeight: 500, maxHeight: .infinity)
    }

    @ViewBuilder
    private func usageCard(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: profile.icon).foregroundStyle(activeID == profile.id ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(profile.name).font(.headline)
                        if activeID == profile.id { Text(AppStrings.t("ATIVA", "ACTIVE")).font(.caption2.weight(.bold)).foregroundStyle(.blue) }
                    }
                    Text(profile.email ?? AppStrings.t("E-mail não identificado", "Email not identified")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let fetchedAt = profile.usage?.fetchedAt {
                    Text("Atualizado \(fetchedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let usage = profile.usage, !usage.quotas.isEmpty {
                ForEach(usage.quotas, id: \.key) { quota in quotaRow(quota) }
                if let tokens = usage.tokens {
                    HStack(spacing: 12) {
                        Label("\(tokens.total.formatted()) tokens (inclui cache)", systemImage: "number")
                        Text("Entrada \(tokens.input.formatted())")
                        Text("Saída \(tokens.output.formatted())")
                        Text("\(tokens.messageCount) respostas")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Uso indisponível — refaça o login desta conta.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func quotaRow(_ quota: ClaudeQuota) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(quota.key).font(.subheadline.weight(.medium))
                Spacer()
                Text(AppStrings.t("\(Int(quota.usedPercent.rounded()))% usado", "\(Int(quota.usedPercent.rounded()))% used")).font(.subheadline.weight(.semibold))
            }
            ProgressView(value: min(max(quota.usedPercent / 100, 0), 1))
                .tint(quota.usedPercent >= 90 ? .red : quota.usedPercent >= 70 ? .orange : .blue)
            if let resetAt = quota.resetAt {
                Text("Renova \(resetAt, style: .date) às \(resetAt, style: .time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
