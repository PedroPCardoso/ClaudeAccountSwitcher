import Foundation

/// Constrói a série temporal diária de tokens a partir dos `.jsonl` de sessão dos perfis
/// recebidos. A seleção de contas é aplicada pelo CALLER (passa só os perfis escolhidos);
/// este serviço apenas agrega o que recebe.
///
/// Espelha o entendimento de estrutura de `ClaudeUsageService.tokenUsage`/`parseTokenFile`:
/// cada linha `assistant` traz `message.usage` com `input_tokens`/`output_tokens`/
/// `cache_read_input_tokens`/`cache_creation_input_tokens`; a diferença é que aqui também lemos
/// o `timestamp` (ISO8601) do nível do objeto para fazer bucket por dia. Linha sem timestamp
/// ou sem usage válido é ignorada; arquivo vazio contribui 0.
public struct UsageHistoryService: Sendable {
    private let cache = DailyTokenUsageCache()

    public init() {}

    /// Série diária ordenada (ascendente) somando os perfis recebidos. Dias após `now` são
    /// descartados (defesa contra timestamps futuros por relógio torto). Perfis vazios → `[]`.
    public func dailyUsage(profiles: [Profile], now: Date, calendar: Calendar = .current) -> [DailyTokenUsage] {
        guard !profiles.isEmpty else { return [] }
        let lastDay = calendar.startOfDay(for: now)
        var byDay: [Date: [UUID: Int]] = [:]

        for profile in profiles {
            let projects = profile.directory.appendingPathComponent("projects", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let signature = DailyTokenUsageCache.Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize ?? -1)
                let buckets: [Date: Int]
                if let cached = cache.buckets(for: url.path, matching: signature) {
                    buckets = cached
                } else {
                    let parsed = Self.parseFile(url, calendar: calendar)
                    cache.store(parsed, for: url.path, signature: signature)
                    buckets = parsed
                }
                for (day, tokens) in buckets where tokens != 0 && day <= lastDay {
                    byDay[day, default: [:]][profile.id, default: 0] += tokens
                }
            }
        }

        return byDay.keys.sorted().map { DailyTokenUsage(day: $0, perProfile: byDay[$0]!) }
    }

    /// Lê um único `.jsonl` e devolve tokens somados por início-de-dia. Cada linha `assistant`
    /// com `timestamp` e `message.usage` válidos é somada ao seu bucket; o resto é ignorado.
    static func parseFile(_ url: URL, calendar: Calendar) -> [Date: Int] {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var buckets: [Date: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let timestamp = object["timestamp"] as? String,
                  let date = ClaudeUsageService.parseResetDate(timestamp),
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let tokens = ((usage["input_tokens"] as? NSNumber)?.intValue ?? 0)
                + ((usage["output_tokens"] as? NSNumber)?.intValue ?? 0)
                + ((usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0)
                + ((usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0)
            let day = calendar.startOfDay(for: date)
            buckets[day, default: 0] += tokens
        }
        return buckets
    }
}

/// Cache thread-safe dos buckets diários por arquivo `.jsonl`, chaveado por (mtime, tamanho) —
/// mesmo padrão do `TokenUsageCache` de `ClaudeUsageService`. Como as sessões são majoritariamente
/// append-only, um recálculo típico só relê os poucos arquivos que mudaram.
final class DailyTokenUsageCache: @unchecked Sendable {
    struct Signature: Equatable { let modifiedAt: Date?; let size: Int }
    private let lock = NSLock()
    private var entries: [String: (signature: Signature, buckets: [Date: Int])] = [:]

    func buckets(for path: String, matching signature: Signature) -> [Date: Int]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature else { return nil }
        return entry.buckets
    }

    func store(_ buckets: [Date: Int], for path: String, signature: Signature) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (signature, buckets)
    }
}
