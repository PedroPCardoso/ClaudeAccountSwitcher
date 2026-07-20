import SwiftUI
import ClaudeAccountSwitcherCore

struct PreferencesView: View {
    let profiles: [Profile]
    let activeID: UUID?
    let onActivate: (Profile) -> Void
    let onRelogin: (Profile) -> Void
    let onRename: (Profile) -> Void
    let onRemove: (Profile) -> Void
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contas Claude").font(.title2.weight(.semibold))
            Text("As contas ficam isoladas. A conta ativa será usada por novas sessões do Claude Code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nenhuma conta cadastrada").font(.headline)
                    Text("Adicione ou importe uma conta pelo menu da barra de ferramentas.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Os perfis e credenciais serão preservados ao desinstalar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Desinstalar aplicativo…", role: .destructive) { onUninstall() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 700, height: 390)
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.icon)
                .font(.title2)
                .foregroundStyle(activeID == profile.id ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name).fontWeight(.medium)
                    if activeID == profile.id {
                        Text("ATIVA")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.14), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text(profile.email.map { "E-mail: \($0)" } ?? "E-mail não identificado • \(profileType(profile.kind))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLabel(profile.health))
                    .font(.caption2)
                    .foregroundStyle(statusColor(profile.health))
                if let usage = profile.usage {
                    Text(usage.quotas.map { quotaText($0) }.joined(separator: "  •  "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Uso: indisponível até autenticar OAuth")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if activeID != profile.id {
                Button("Ativar") { onActivate(profile) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Refazer login") { onRelogin(profile) }
                .buttonStyle(.borderless)
            Button { onRename(profile) } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Renomear perfil")
            Button(role: .destructive) { onRemove(profile) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remover perfil")
        }
        .padding(.vertical, 5)
    }

    private func profileType(_ kind: ProfileKind) -> String {
        switch kind {
        case .claudeSubscription: return "Claude Pro/Max"
        case .anthropicConsole: return "Anthropic Console"
        case .custom: return "Perfil importado"
        }
    }

    private func statusLabel(_ health: ProfileHealth) -> String {
        switch health {
        case .ready: return "Autenticada"
        case .expired: return "Login expirado"
        case .unavailable: return "Indisponível"
        case .unknown: return "Status não verificado"
        }
    }

    private func statusColor(_ health: ProfileHealth) -> Color {
        switch health {
        case .ready: return .green
        case .expired, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private func quotaText(_ quota: ClaudeQuota) -> String {
        let percent = "\(Int(quota.usedPercent.rounded()))%"
        guard let resetAt = quota.resetAt else { return "\(quota.key): \(percent) usado" }
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        return "\(quota.key): \(percent) usado (renova \(formatter.string(from: resetAt)))"
    }
}
