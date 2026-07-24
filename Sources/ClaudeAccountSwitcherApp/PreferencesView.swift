import SwiftUI
import ClaudeAccountSwitcherCore

struct PreferencesView: View {
    let profiles: [Profile]
    let activeID: UUID?
    let paseoDetected: Bool
    let paseoConfigured: Bool
    let onActivate: (Profile) -> Void
    let onRelogin: (Profile) -> Void
    let onRename: (Profile) -> Void
    let onRemove: (Profile) -> Void
    let onUninstall: () -> Void
    let onAdd: () -> Void
    let onImport: () -> Void
    let onMigrate: () -> Void
    let onIntegratePaseo: () -> Void

    @AppStorage(FiveHourAlertThreshold.defaultsKey) private var fiveHourThreshold: Double = FiveHourAlertThreshold.default
    @AppStorage(FiveHourAlertSound.defaultsKey) private var fiveHourSoundRaw: String = FiveHourAlertSound.default.rawValue
    @AppStorage(WeeklyCreditsAlertThreshold.defaultsKey) private var weeklyCreditsThreshold: Double = WeeklyCreditsAlertThreshold.default
    @AppStorage(AppPreferences.relaunchDesktopOnSwitch) private var relaunchDesktopOnSwitch: Bool = false
    @AppStorage(AppPreferences.showUsageInMenuBar) private var showUsageInMenuBar: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppStrings.t("Contas Claude", "Claude Accounts")).font(.title2.weight(.semibold))
            Text(AppStrings.t("As contas ficam isoladas. A conta ativa será usada por novas sessões do Claude Code.", "Accounts are isolated. The active account is used by new Claude Code sessions."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(AppStrings.t("Nenhuma conta cadastrada", "No accounts configured")).font(.headline)
                    Text(AppStrings.t("Adicione ou importe uma conta pelo menu da barra de ferramentas.", "Add or import an account from the menu bar.")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            HStack(spacing: 16) {
                Stepper(value: $fiveHourThreshold, in: 1...100, step: 5) {
                    Text(AppStrings.t("Alertar em \(Int(fiveHourThreshold))% da janela de 5h", "Alert at \(Int(fiveHourThreshold))% of the 5-hour window"))
                }
                Picker(AppStrings.t("Som:", "Sound:"), selection: $fiveHourSoundRaw) {
                    ForEach(FiveHourAlertSound.allCases, id: \.self) { Text(soundLabel($0)).tag($0.rawValue) }
                }
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 16) {
                Stepper(value: $weeklyCreditsThreshold, in: 1...100, step: 5) {
                    Text(AppStrings.t("Avisar quando restarem \(Int(weeklyCreditsThreshold))% ou mais dos créditos semanais no dia da renovação", "Alert when \(Int(weeklyCreditsThreshold))% or more of weekly credits remain on renewal day"))
                }
                Spacer()
            }
            Toggle(isOn: $showUsageInMenuBar) {
                Text(AppStrings.t("Mostrar % da janela de 5h da conta ativa na barra de menu", "Show the active account's 5-hour usage % in the menu bar"))
            }
            .help(AppStrings.t("Exibe o percentual usado ao lado do ícone, colorido por faixa (verde/laranja/vermelho).", "Shows the used percentage next to the icon, coloured by tier (green/orange/red)."))
            Toggle(isOn: $relaunchDesktopOnSwitch) {
                Text(AppStrings.t("Reabrir o app nativo do Claude ao trocar de conta", "Reopen the native Claude app when switching accounts"))
            }
            .help(AppStrings.t("Desativado por padrão. O terminal troca de conta sem reabrir o app nativo.", "Off by default. The terminal switches accounts without reopening the native app."))

            if paseoDetected {
                HStack(spacing: 8) {
                    Button(paseoConfigured ? AppStrings.t("Reconfigurar integração com Paseo…", "Reconfigure Paseo integration…") : AppStrings.t("Integrar com Paseo…", "Integrate with Paseo…")) { onIntegratePaseo() }
                        .buttonStyle(.bordered)
                    if paseoConfigured {
                        Text(AppStrings.t("Paseo já segue a conta ativa", "Paseo already follows the active account"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(AppStrings.t("Paseo detectado — sessões novas ainda não seguem a troca de conta", "Paseo detected — new sessions don't follow account switches yet"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Divider()
            HStack {
                Button(AppStrings.t("Adicionar conta…", "Add account…")) { onAdd() }.buttonStyle(.borderedProminent)
                Button(AppStrings.t("Importar perfil…", "Import profile…")) { onImport() }.buttonStyle(.bordered)
                Button(AppStrings.t("Migrar perfis…", "Migrate profiles…")) { onMigrate() }.buttonStyle(.bordered)
                Spacer()
            }
            HStack {
                Text("Os perfis e credenciais serão preservados ao desinstalar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AppStrings.t("Desinstalar aplicativo…", "Uninstall app…"), role: .destructive) { onUninstall() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 700, height: 450)
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
        case .unknown: return "Status não verificado"
        }
    }

    private func statusColor(_ health: ProfileHealth) -> Color {
        switch health {
        case .ready: return .green
        case .expired: return .orange
        case .unknown: return .secondary
        }
    }

    private func soundLabel(_ sound: FiveHourAlertSound) -> String {
        switch sound {
        case .none: return AppStrings.t("Nenhum", "None")
        case .standard: return AppStrings.t("Padrão", "Default")
        case .basso: return "Basso"
        case .glass: return "Glass"
        case .hero: return "Hero"
        case .ping: return "Ping"
        case .sosumi: return "Sosumi"
        }
    }

    private func quotaText(_ quota: ClaudeQuota) -> String {
        let percent = QuotaFormatter.percent(quota.usedPercent)
        guard let resetAt = quota.resetAt else { return "\(quota.key): \(percent) usado" }
        return "\(quota.key): \(percent) usado (renova \(QuotaFormatter.resetTime(resetAt)))"
    }
}
