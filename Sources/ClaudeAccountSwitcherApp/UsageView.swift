import SwiftUI
import ClaudeAccountSwitcherCore

struct UsageView: View {
    let profiles: [Profile]
    let activeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uso do Claude").font(.title2.weight(.semibold))
            Text("Cotas reais das contas Pro/Max autenticadas no Claude Code.")
                .font(.subheadline).foregroundStyle(.secondary)

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nenhuma conta").font(.headline)
                    Text("Adicione uma conta para acompanhar o uso.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(profiles) { profile in usageCard(profile) }
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("Os percentuais são consultados diretamente na conta selecionada. O endpoint de uso é uma interface de consumidor e pode sofrer alterações.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 720, height: 500)
    }

    @ViewBuilder
    private func usageCard(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: profile.icon).foregroundStyle(activeID == profile.id ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(profile.name).font(.headline)
                        if activeID == profile.id { Text("ATIVA").font(.caption2.weight(.bold)).foregroundStyle(.blue) }
                    }
                    Text(profile.email ?? "E-mail não identificado").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let fetchedAt = profile.usage?.fetchedAt {
                    Text("Atualizado \(fetchedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let usage = profile.usage, !usage.quotas.isEmpty {
                ForEach(usage.quotas, id: \.key) { quota in quotaRow(quota) }
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
                Text("\(Int(quota.usedPercent.rounded()))% usado").font(.subheadline.weight(.semibold))
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
