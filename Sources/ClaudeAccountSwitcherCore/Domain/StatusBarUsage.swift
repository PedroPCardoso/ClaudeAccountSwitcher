import Foundation

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
}
