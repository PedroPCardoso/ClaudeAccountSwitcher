import Foundation

/// Uso do plano Cursor no ciclo de faturamento atual. Valores monetários em centavos
/// (como a API devolve).
///
/// A página "Included in Pro" do Cursor mostra **só duas barras**. Os nomes dos campos
/// da API e as `*DisplayMessage` **não** batem com essa página — a fonte de verdade é
/// o que o site renderiza:
///
/// | O que o dashboard mostra | Campo da API | Exemplo (jul/2026) |
/// |---|---|---|
/// | Barra "Cursor Models" (Grok, Composer) | `autoPercentUsed` | 0,68 → **1%** |
/// | Barra "Other Models" (Claude, GPT, …) | `apiPercentUsed` | 19,4 → **19%** |
///
/// Armadilhas (não usar para espelhar o site):
/// - `totalSpend / limit` (~54%) — a API também manda isso em `displayMessage`, mas
///   **não aparece** na seção "Included in Pro".
/// - `totalPercentUsed` (~3%) — casa com `autoModelSelectedDisplayMessage`, **não** com
///   a barra "Cursor Models" do site (que usa `autoPercentUsed`).
public struct CursorPlanUsage: Codable, Equatable, Sendable {
    public let totalSpendCents: Double
    public let includedSpendCents: Double
    public let limitCents: Double
    public let remainingCents: Double
    public let billingCycleStart: Date
    public let billingCycleEnd: Date
    /// Barra "Cursor Models" do dashboard (`autoPercentUsed`).
    public let cursorModelsPercent: Double?
    /// Barra "Other Models" do dashboard (`apiPercentUsed`).
    public let otherModelsPercent: Double?

    /// Gasto ÷ limite em centavos. Existe na API (`displayMessage`), mas **não** é o que
    /// a página "Included in Pro" exibe — preferir `dashboardUsedPercent` / as duas barras.
    public var usedPercent: Double {
        guard limitCents > 0 else { return 0 }
        return (totalSpendCents / limitCents) * 100
    }

    /// Percentual para badge/alerta: o maior das duas barras do dashboard (o que o
    /// usuário vê como uso incluído). `nil` se nenhuma barra veio da API.
    public var dashboardUsedPercent: Double? {
        [cursorModelsPercent, otherModelsPercent].compactMap { $0 }.max()
    }

    public init(
        totalSpendCents: Double,
        includedSpendCents: Double,
        limitCents: Double,
        remainingCents: Double,
        billingCycleStart: Date,
        billingCycleEnd: Date,
        cursorModelsPercent: Double? = nil,
        otherModelsPercent: Double? = nil
    ) {
        self.totalSpendCents = totalSpendCents
        self.includedSpendCents = includedSpendCents
        self.limitCents = limitCents
        self.remainingCents = remainingCents
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.cursorModelsPercent = cursorModelsPercent
        self.otherModelsPercent = otherModelsPercent
    }
}

/// Agregado de tokens + custo para um único `modelIntent` no ciclo.
public struct CursorModelUsage: Codable, Equatable, Sendable {
    public let modelIntent: String
    public let input: Int
    public let output: Int
    public let cacheWrite: Int
    public let cacheRead: Int
    public let costCents: Double

    public var totalTokens: Int { input + output + cacheWrite + cacheRead }

    public init(modelIntent: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int, costCents: Double) {
        self.modelIntent = modelIntent
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.costCents = costCents
    }
}

/// Família de modelo, para agrupar GPT/Claude/Composer/etc. no resumo da UI.
public enum CursorModelFamily: String, Codable, Equatable, Sendable, CaseIterable {
    case claude, gpt, gemini, grok, composer, other

    public static func classify(_ modelIntent: String) -> CursorModelFamily {
        let lower = modelIntent.lowercased()
        if lower.hasPrefix("claude") || lower.contains("claude") { return .claude }
        if lower.hasPrefix("gpt") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return .gpt }
        if lower.hasPrefix("gemini") || lower.contains("gemini") { return .gemini }
        if lower.hasPrefix("grok") || lower.contains("grok") { return .grok }
        if lower.hasPrefix("composer") || lower == "default" || lower == "premium" || lower.hasPrefix("auto") { return .composer }
        return .other
    }
}

/// Gasto diário por modelo (uma linha de `GetDailySpendByCategory`).
public struct CursorDailySpend: Codable, Equatable, Hashable, Sendable {
    public let day: Date
    public let modelIntent: String
    public let spendCents: Double
    public let totalTokens: Int

    public init(day: Date, modelIntent: String, spendCents: Double, totalTokens: Int) {
        self.day = day
        self.modelIntent = modelIntent
        self.spendCents = spendCents
        self.totalTokens = totalTokens
    }
}

/// Snapshot completo de uso do Cursor, persistido em `cursor-usage.json`.
public struct CursorUsageSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let email: String?
    public let plan: String?
    public let planUsage: CursorPlanUsage?
    public let models: [CursorModelUsage]
    public let daily: [CursorDailySpend]
    public let source: String

    public init(
        fetchedAt: Date = .now,
        email: String? = nil,
        plan: String? = nil,
        planUsage: CursorPlanUsage? = nil,
        models: [CursorModelUsage] = [],
        daily: [CursorDailySpend] = [],
        source: String = "Cursor Dashboard API"
    ) {
        self.fetchedAt = fetchedAt
        self.email = email
        self.plan = plan
        self.planUsage = planUsage
        self.models = models
        self.daily = daily
        self.source = source
    }

    /// Soma de tokens por família a partir de `models`.
    public func tokensByFamily() -> [CursorModelFamily: Int] {
        var result: [CursorModelFamily: Int] = [:]
        for model in models {
            let family = CursorModelFamily.classify(model.modelIntent)
            result[family, default: 0] += model.totalTokens
        }
        return result
    }

    /// Soma de custo (centavos) por família.
    public func costByFamily() -> [CursorModelFamily: Double] {
        var result: [CursorModelFamily: Double] = [:]
        for model in models {
            let family = CursorModelFamily.classify(model.modelIntent)
            result[family, default: 0] += model.costCents
        }
        return result
    }
}
