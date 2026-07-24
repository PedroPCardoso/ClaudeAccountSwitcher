import Foundation

/// Custo estimado em USD de um `TokenBreakdown`, por modelo. Lógica pura, sem I/O nem rede.
///
/// Tabela FIXA no código (escolha KISS: sem dependência de rede; atualizar quando a Anthropic
/// mudar a tabela). Espelha os multiplicadores de cache da Anthropic que o `CostUsagePricing` do
/// CodexBar aplica: `cacheRead` ≈ 0,1x do input, escrita de cache 5m = 1,25x, escrita de cache
/// 1h = 2x, `output` ≈ 5x. Os preços-base (input/output) são por família de modelo (Opus/Sonnet/
/// Haiku); versões dentro da família compartilham o mesmo preço público atual. Modelo desconhecido
/// → `nil` (o caller trata como "não precificado", nunca como custo 0 disfarçado).
public enum ModelPricing {
    /// Preço em USD por 1 token, por tipo.
    public struct Rate: Equatable, Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite5m: Double
        public let cacheWrite1h: Double
    }

    public enum Family: String, CaseIterable, Sendable { case opus, sonnet, haiku }

    /// Preços por MILHÃO de tokens (base). Os de cache derivam do input pelos multiplicadores da
    /// Anthropic; deixados explícitos para leitura e para não recalcular a cada chamada.
    private static let perMillion: [Family: Rate] = [
        .opus:   Rate(input: 15, output: 75, cacheRead: 1.5,  cacheWrite5m: 18.75, cacheWrite1h: 30),
        .sonnet: Rate(input: 3,  output: 15, cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        .haiku:  Rate(input: 1,  output: 5,  cacheRead: 0.10, cacheWrite5m: 1.25,  cacheWrite1h: 2),
    ]

    /// Identifica a família a partir do id do modelo (ex.: `claude-sonnet-4-5-…`,
    /// `claude-3-5-haiku-…`, `claude-opus-4-…`). `nil` se não reconhecer.
    public static func family(for model: String) -> Family? {
        let name = model.lowercased()
        if name.contains("opus") { return .opus }
        if name.contains("sonnet") { return .sonnet }
        if name.contains("haiku") { return .haiku }
        return nil
    }

    /// Custo USD do breakdown para o modelo dado, ou `nil` se o modelo não estiver na tabela.
    public static func costUSD(model: String, tokens: TokenBreakdown) -> Double? {
        guard let family = family(for: model), let rate = perMillion[family] else { return nil }
        let perToken = 1_000_000.0
        return Double(tokens.input)          * rate.input        / perToken
             + Double(tokens.output)         * rate.output       / perToken
             + Double(tokens.cacheRead)      * rate.cacheRead     / perToken
             + Double(tokens.cacheCreation5m) * rate.cacheWrite5m / perToken
             + Double(tokens.cacheCreation1h) * rate.cacheWrite1h / perToken
    }
}
