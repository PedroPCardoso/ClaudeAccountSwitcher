import Foundation

/// Faixa de uso de uma cota, com os mesmos limiares usados na `UsageView`
/// (< 70 = ok, 70–89 = atenção, >= 90 = crítico). Tipo puro, testável no Core;
/// o mapeamento para cores concretas fica na camada de view.
public enum UsageTier: Sendable, Equatable {
    case ok, warning, critical

    public static func forPercent(_ p: Double) -> UsageTier {
        if p >= 90 { return .critical }
        if p >= 70 { return .warning }
        return .ok
    }
}
