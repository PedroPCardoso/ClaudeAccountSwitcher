import Foundation

/// Fonte do percentual exibido ao lado do ícone na barra de menu.
public enum StatusBarUsageSource: String, Codable, Equatable, Sendable, CaseIterable {
    case off
    case claude
    case cursor
    case both

    public static let defaultsKey = "statusBarUsageSource"
    /// Chave legada (Bool). Na primeira leitura, `true` → `.claude`, `false`/ausente → `.off`.
    public static let legacyDefaultsKey = "showUsageInMenuBar"

    /// Lê a preferência, migrando o Bool legado se a nova chave ainda não existir.
    public static func resolve(_ defaults: UserDefaults = .standard) -> StatusBarUsageSource {
        if let raw = defaults.string(forKey: defaultsKey), let value = StatusBarUsageSource(rawValue: raw) {
            return value
        }
        // Migração one-shot do toggle antigo.
        if defaults.object(forKey: legacyDefaultsKey) != nil {
            let migrated: StatusBarUsageSource = defaults.bool(forKey: legacyDefaultsKey) ? .claude : .off
            defaults.set(migrated.rawValue, forKey: defaultsKey)
            return migrated
        }
        return .off
    }
}

/// Um segmento do rótulo da barra de menu (texto + faixa de cor).
public struct StatusBarUsageSegment: Equatable, Sendable {
    public let text: String
    public let tier: UsageTier
    public init(text: String, tier: UsageTier) {
        self.text = text
        self.tier = tier
    }
}

/// Monta o rótulo curto de uso exibido na barra de menu a partir do usage da conta ativa.
/// Casa a cota pela identidade estável `QuotaKind.fiveHour` (não pelo `key` localizado), para
/// não quebrar quando o rótulo muda de idioma. Vive no Core por ser lógica pura e testável —
/// a cor por faixa (`UsageTier`) é aplicada na camada de view.
public enum StatusBarUsage {
    /// "72%" (arredondado) da cota de 5h da conta ativa, ou `nil` se não houver dado.
    public static func label(activeUsage: ClaudeUsageSnapshot?) -> String? {
        guard let quota = activeUsage?.quotas.first(where: { $0.kind == .fiveHour }) else { return nil }
        return "\(Int(quota.usedPercent.rounded()))%"
    }

    /// Segmentos coloridos conforme a fonte escolhida. Com `.both`: "C 72%" + "⌘ 14%".
    public static func segments(
        source: StatusBarUsageSource,
        activeClaude: ClaudeUsageSnapshot?,
        cursor: CursorUsageSnapshot?
    ) -> [StatusBarUsageSegment] {
        switch source {
        case .off:
            return []
        case .claude:
            return claudeSegment(activeClaude).map { [$0] } ?? []
        case .cursor:
            return cursorSegment(cursor).map { [$0] } ?? []
        case .both:
            var result: [StatusBarUsageSegment] = []
            if let c = claudeSegment(activeClaude) {
                result.append(StatusBarUsageSegment(text: "C \(c.text)", tier: c.tier))
            }
            if let u = cursorSegment(cursor) {
                result.append(StatusBarUsageSegment(text: "⌘ \(u.text)", tier: u.tier))
            }
            return result
        }
    }

    private static func claudeSegment(_ usage: ClaudeUsageSnapshot?) -> StatusBarUsageSegment? {
        guard let quota = usage?.quotas.first(where: { $0.kind == .fiveHour }) else { return nil }
        return StatusBarUsageSegment(
            text: "\(Int(quota.usedPercent.rounded()))%",
            tier: UsageTier.forPercent(quota.usedPercent))
    }

    private static func cursorSegment(_ usage: CursorUsageSnapshot?) -> StatusBarUsageSegment? {
        guard let plan = usage?.planUsage,
              let percent = plan.dashboardUsedPercent else { return nil }
        return StatusBarUsageSegment(
            text: "\(Int(percent.rounded()))%",
            tier: UsageTier.forPercent(percent))
    }
}
