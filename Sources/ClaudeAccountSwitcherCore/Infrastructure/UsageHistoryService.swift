import Foundation

/// Constrói a série temporal diária de tokens a partir dos `.jsonl` de sessão dos perfis
/// recebidos. A seleção de contas é aplicada pelo CALLER (passa só os perfis escolhidos);
/// este serviço apenas agrega o que recebe.
///
/// Estrutura de cada linha `assistant`: `message.usage` traz `input_tokens`/`output_tokens`/
/// `cache_read_input_tokens`/`cache_creation_input_tokens`, e o `timestamp` (ISO8601) fica no
/// nível do objeto (usado para o bucket por dia). Linha sem timestamp ou sem usage válido é
/// ignorada; arquivo vazio contribui 0.
///
/// Deduplicação (mesma lógica do `CostUsageScanner` do CodexBar / `ccusage`): o Claude Code grava
/// vários chunks de streaming para a MESMA mensagem, todos com `message.id` + `requestId` iguais e
/// o mesmo `usage`. Somar todas as linhas conta a mesma mensagem N vezes (observado ~2x no total
/// real). Contamos cada `message.id:requestId` uma única vez — dentro do arquivo e também entre
/// arquivos da mesma conta (sessões retomadas copiam o histórico). Linhas antigas sem os dois IDs
/// são tratadas como distintas, para não descartar uso legítimo.
public struct UsageHistoryService: Sendable {
    private let cache = DailyTokenUsageCache()

    public init() {}

    /// Uma mensagem `assistant` já parseada: `key` é `"message.id:requestId"` quando ambos existem
    /// (permite dedup), ou `nil` em logs antigos que omitem os IDs (cada linha conta como distinta).
    /// `tokens` traz a quebra por tipo (input/output/cacheRead/cache 1h/5m); `costUSD` é o custo
    /// estimado pelo modelo da linha, ou `nil` quando o modelo não está na tabela de preços.
    struct ParsedRow: Equatable, Sendable {
        let key: String?
        let day: Date
        let tokens: TokenBreakdown
        let costUSD: Double?
    }

    /// Série diária ordenada (ascendente) somando os perfis recebidos, com a quebra de tokens por
    /// tipo e o custo USD estimado por perfil. Dias após `now` são descartados (defesa contra
    /// timestamps futuros por relógio torto). Perfis vazios → `[]`.
    public func dailyUsage(profiles: [Profile], now: Date, calendar: Calendar = .current) -> [DailyTokenUsage] {
        guard !profiles.isEmpty else { return [] }
        let lastDay = calendar.startOfDay(for: now)
        var tokensByDay: [Date: [UUID: TokenBreakdown]] = [:]
        var costByDay: [Date: [UUID: Double]] = [:]

        for profile in profiles {
            let projects = profile.directory.appendingPathComponent("projects", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            // Dedup entre arquivos da conta: o mesmo `message.id:requestId` (ex.: sessão retomada
            // que copia o histórico) conta uma vez só.
            var seenKeys = Set<String>()
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let signature = DailyTokenUsageCache.Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize ?? -1)
                let rows: [ParsedRow]
                if let cached = cache.rows(for: url.path, matching: signature) {
                    rows = cached
                } else {
                    let parsed = Self.parseFile(url, calendar: calendar)
                    cache.store(parsed, for: url.path, signature: signature)
                    rows = parsed
                }
                for row in rows {
                    if let key = row.key, !seenKeys.insert(key).inserted { continue }
                    guard row.day <= lastDay else { continue }
                    tokensByDay[row.day, default: [:]][profile.id, default: .zero] += row.tokens
                    if let cost = row.costUSD { costByDay[row.day, default: [:]][profile.id, default: 0] += cost }
                }
            }
        }

        return tokensByDay.keys.sorted().map {
            DailyTokenUsage(day: $0, breakdownPerProfile: tokensByDay[$0]!, costPerProfile: costByDay[$0] ?? [:])
        }
    }

    /// Lê um único `.jsonl` e devolve as mensagens `assistant` já deduplicadas DENTRO do arquivo
    /// (por `message.id:requestId`, mantendo a última — os chunks são idênticos). Cada linha traz a
    /// quebra por tipo (com o split de escrita de cache 1h vs 5m, que têm preços diferentes) e o
    /// custo estimado pelo `message.model`. Linhas sem timestamp/usage válidos são ignoradas;
    /// linhas com total de tokens 0 não geram linha.
    static func parseFile(_ url: URL, calendar: Calendar) -> [ParsedRow] {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        func int(_ v: Any?) -> Int { max(0, (v as? NSNumber)?.intValue ?? 0) }
        var keyed: [String: ParsedRow] = [:]
        var unkeyed: [ParsedRow] = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let timestamp = object["timestamp"] as? String,
                  let date = ClaudeUsageService.parseResetDate(timestamp),
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let cacheCreationTotal = int(usage["cache_creation_input_tokens"])
            // Escrita de cache dividida por TTL: 1h custa 2x input, 5m custa 1,25x. O que não vier
            // marcado como 1h é tratado como 5m (limitado ao total, defesa contra dado inconsistente).
            let cacheCreation1h = min(cacheCreationTotal, int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
            let tokens = TokenBreakdown(
                input: int(usage["input_tokens"]),
                output: int(usage["output_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]),
                cacheCreation5m: cacheCreationTotal - cacheCreation1h,
                cacheCreation1h: cacheCreation1h,
                messageCount: 1)
            guard tokens.total != 0 else { continue }
            let cost = (message["model"] as? String).flatMap { ModelPricing.costUSD(model: $0, tokens: tokens) }
            let day = calendar.startOfDay(for: date)
            if let messageId = message["id"] as? String, let requestId = object["requestId"] as? String {
                let key = "\(messageId):\(requestId)"
                keyed[key] = ParsedRow(key: key, day: day, tokens: tokens, costUSD: cost)
            } else {
                unkeyed.append(ParsedRow(key: nil, day: day, tokens: tokens, costUSD: cost))
            }
        }
        return keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed
    }
}

/// Cache thread-safe das linhas parseadas por arquivo `.jsonl`, chaveado por (mtime, tamanho) —
/// mesmo padrão do `TokenUsageCache` de `ClaudeUsageService`. Como as sessões são majoritariamente
/// append-only, um recálculo típico só relê os poucos arquivos que mudaram.
final class DailyTokenUsageCache: @unchecked Sendable {
    struct Signature: Equatable { let modifiedAt: Date?; let size: Int }
    private let lock = NSLock()
    private var entries: [String: (signature: Signature, rows: [UsageHistoryService.ParsedRow])] = [:]

    func rows(for path: String, matching signature: Signature) -> [UsageHistoryService.ParsedRow]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature else { return nil }
        return entry.rows
    }

    func store(_ rows: [UsageHistoryService.ParsedRow], for path: String, signature: Signature) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (signature, rows)
    }
}
