import Foundation

/// Tokens somados de um único dia (início do dia no fuso local), quebrados por perfil.
/// Só contém os perfis que o caller já filtrou pela seleção — a agregação nunca decide
/// sozinha quais contas entram.
public struct DailyTokenUsage: Equatable, Sendable {
    public let day: Date                 // início do dia (local)
    public let perProfile: [UUID: Int]   // tokens por perfil no dia (só selecionados)
    public var total: Int { perProfile.values.reduce(0, +) }

    public init(day: Date, perProfile: [UUID: Int]) {
        self.day = day; self.perProfile = perProfile
    }
}

/// Veredicto puro "1 Max provavelmente cobre" vs "o uso justifica 2–3 Pro" vs "inconclusivo".
/// O enum e a decisão vivem no Core; o texto bilíngue de apresentação é montado na app a
/// partir do `verdict`. O `rationale` aqui é uma nota curta e neutra (não localizada).
public struct PlanRecommendation: Equatable, Sendable {
    public enum Verdict: String, Sendable { case singleMaxLikelyEnough, multipleProJustified, inconclusive }
    public let verdict: Verdict
    public let rationale: String

    public init(verdict: Verdict, rationale: String) {
        self.verdict = verdict; self.rationale = rationale
    }

    /// Decide a partir do volume agregado e da concorrência observada entre as contas
    /// selecionadas. Deliberadamente NÃO usa preço nem limite absoluto de plano (que mudam e
    /// não são expostos pela API): a heurística é relativa à própria série.
    ///
    /// - `selectedProfileCount`: quantas contas o caller passou (0 → inconclusivo).
    /// - `minimumActiveDays`: histórico mínimo com uso para um veredicto; abaixo disso →
    ///   inconclusivo.
    /// - `significanceShare`: fração do total do dia acima da qual a contribuição de uma conta
    ///   conta como "demanda relevante" naquele dia.
    /// - `concurrencyRatioThreshold`: fração dos dias ativos com ≥2 contas relevantes acima da
    ///   qual a demanda simultânea recorrente justifica múltiplos Pro.
    public static func evaluate(series: [DailyTokenUsage],
                                selectedProfileCount: Int,
                                minimumActiveDays: Int = 5,
                                significanceShare: Double = 0.25,
                                concurrencyRatioThreshold: Double = 0.4) -> PlanRecommendation {
        guard selectedProfileCount > 0 else {
            return PlanRecommendation(verdict: .inconclusive, rationale: "No accounts selected.")
        }
        let activeDays = series.filter { $0.total > 0 }
        guard activeDays.count >= minimumActiveDays else {
            return PlanRecommendation(verdict: .inconclusive,
                                      rationale: "Only \(activeDays.count) day(s) of usage; need \(minimumActiveDays) to advise.")
        }

        let concurrentDays = activeDays.filter { day in
            let floor = Double(day.total) * significanceShare
            let relevant = day.perProfile.values.filter { $0 > 0 && Double($0) >= floor }
            return relevant.count >= 2
        }
        let concurrencyRatio = Double(concurrentDays.count) / Double(activeDays.count)

        if selectedProfileCount >= 2 && concurrencyRatio >= concurrencyRatioThreshold {
            let pct = Int((concurrencyRatio * 100).rounded())
            return PlanRecommendation(verdict: .multipleProJustified,
                                      rationale: "Concurrent demand on \(pct)% of active days across \(selectedProfileCount) accounts.")
        }
        return PlanRecommendation(verdict: .singleMaxLikelyEnough,
                                  rationale: "Usage rarely overlaps across accounts (\(Int((concurrencyRatio * 100).rounded()))% of active days).")
    }
}

/// Lógica pura de "está selecionado?", separada de `UserDefaults` para ser testável sem I/O.
/// O conjunto persistido guarda os UUIDs SELECIONADOS. Ausência do conjunto (`nil`) = todas as
/// contas selecionadas (comportamento óbvio no primeiro uso). IDs salvos que não existem mais
/// são simplesmente ignorados.
public enum AnalysisSelection {
    public static func isSelected(_ id: UUID, savedRawIDs: [String]?) -> Bool {
        guard let savedRawIDs else { return true }
        return savedRawIDs.contains(id.uuidString)
    }

    public static func selected(from profiles: [Profile], savedRawIDs: [String]?) -> [Profile] {
        profiles.filter { isSelected($0.id, savedRawIDs: savedRawIDs) }
    }
}
