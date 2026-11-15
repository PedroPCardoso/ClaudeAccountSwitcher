import Foundation
import CryptoKit

/// Identidade estável de uma cota, independente do rótulo localizado. Os alertas casam por
/// `kind`; traduzir/alterar o `key` (que é só apresentação) não pode mais quebrá-los.
public enum QuotaKind: String, Codable, Equatable, Sendable { case fiveHour, sevenDay, sevenDayModel }

public struct ClaudeQuota: Codable, Equatable, Sendable {
    public let kind: QuotaKind
    public let key: String
    public let usedPercent: Double
    public let resetAt: Date?

    public init(kind: QuotaKind, key: String, usedPercent: Double, resetAt: Date? = nil) {
        self.kind = kind; self.key = key; self.usedPercent = usedPercent; self.resetAt = resetAt
    }

    private enum CodingKeys: String, CodingKey { case kind, key, usedPercent, resetAt }

    // Decodificação compatível com snapshots persistidos antes do campo `kind` existir:
    // infere o tipo a partir do rótulo legado em vez de falhar (o que derrubaria todo o
    // profiles.json e faria os perfis sumirem).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        self.kind = try container.decodeIfPresent(QuotaKind.self, forKey: .kind) ?? Self.inferKind(fromLegacyKey: key)
    }

    private static func inferKind(fromLegacyKey key: String) -> QuotaKind {
        if key == "Semanal" || key == "Weekly" { return .sevenDay }
        if key.hasPrefix("Semanal ") || key.hasPrefix("Weekly ") { return .sevenDayModel }
        return .fiveHour
    }
}

public struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let plan: String?
    public let quotas: [ClaudeQuota]
    public let source: String
    public let tokens: ClaudeTokenUsage?

    public init(fetchedAt: Date = .now, plan: String? = nil, quotas: [ClaudeQuota], source: String, tokens: ClaudeTokenUsage? = nil) {
        self.fetchedAt = fetchedAt; self.plan = plan; self.quotas = quotas; self.source = source; self.tokens = tokens
    }
}

public struct ClaudeTokenUsage: Codable, Equatable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    public let messageCount: Int

    public var total: Int { input + output + cacheRead + cacheCreation }
    public init(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, messageCount: Int) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheCreation = cacheCreation; self.messageCount = messageCount
    }

    public static let zero = ClaudeTokenUsage(input: 0, output: 0, cacheRead: 0, cacheCreation: 0, messageCount: 0)
    public static func + (lhs: ClaudeTokenUsage, rhs: ClaudeTokenUsage) -> ClaudeTokenUsage {
        ClaudeTokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheCreation: lhs.cacheCreation + rhs.cacheCreation, messageCount: lhs.messageCount + rhs.messageCount)
    }
}

public enum ClaudeUsageError: Error { case tokenUnavailable, invalidResponse, unauthorized }

/// Transporte HTTP injetável — `URLSession.shared` em produção, um stub nos testes.
public typealias UsageTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Política de retry para o fetch de uso. `baseDelay` é o atraso do primeiro retry;
/// cresce exponencialmente com jitter. `baseDelay = 0` desativa a espera (usado em teste).
public struct UsageRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5) {
        self.maxAttempts = max(1, maxAttempts); self.baseDelay = max(0, baseDelay)
    }
}

/// Reads the Claude Code OAuth usage endpoint. The endpoint is a
/// consumer endpoint (not the public Anthropic API) and may change upstream.
public struct ClaudeUsageService: Sendable {
    private let transport: UsageTransport
    private let retry: UsageRetryPolicy
    private let tokenProvider: (@Sendable (URL) -> String?)?
    private let tokenCache = TokenUsageCache()

    public init(retry: UsageRetryPolicy = .init(),
                transport: @escaping UsageTransport = { try await URLSession.shared.data(for: $0) },
                tokenProvider: (@Sendable (URL) -> String?)? = nil) {
        self.retry = retry; self.transport = transport; self.tokenProvider = tokenProvider
    }

    public func fetch(profileDirectory: URL) async throws -> ClaudeUsageSnapshot {
        guard let token = tokenProvider?(profileDirectory) ?? accessToken(profileDirectory: profileDirectory) else { throw ClaudeUsageError.tokenUnavailable }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await fetchWithRetry(request)
        return try parse(data: data)
    }

    /// Executa o request com retry e backoff exponencial + jitter. Repete em erro de rede
    /// (blip transitório) e em HTTP 429/5xx; não repete em 401/403 (auth) nem em 2xx/4xx.
    private func fetchWithRetry(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.invalidResponse }
                if http.statusCode == 401 || http.statusCode == 403 { throw ClaudeUsageError.unauthorized }
                if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    if attempt < retry.maxAttempts { try await backoff(attempt); continue }
                    throw ClaudeUsageError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else { throw ClaudeUsageError.invalidResponse }
                return data
            } catch let error as ClaudeUsageError {
                throw error   // erros lógicos (auth/resposta inválida) não são retentados
            } catch {
                if attempt < retry.maxAttempts { try await backoff(attempt); continue }
                throw error   // erro de rede após esgotar as tentativas
            }
        }
    }

    private func backoff(_ attempt: Int) async throws {
        guard retry.baseDelay > 0 else { return }
        let exponential = retry.baseDelay * pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0...(exponential * 0.25))
        try await Task.sleep(nanoseconds: UInt64((exponential + jitter) * 1_000_000_000))
    }

    private func parse(data: Data) throws -> ClaudeUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeUsageError.invalidResponse }
        var quotas: [ClaudeQuota] = []
        if let five = root["five_hour"] as? [String: Any], let value = five["utilization"] as? NSNumber {
            quotas.append(ClaudeQuota(kind: .fiveHour, key: "Janela 5h", usedPercent: value.doubleValue, resetAt: Self.parseResetDate(five["resets_at"] as? String)))
        }
        if let seven = root["seven_day"] as? [String: Any], let value = seven["utilization"] as? NSNumber {
            quotas.append(ClaudeQuota(kind: .sevenDay, key: "Semanal", usedPercent: value.doubleValue, resetAt: Self.parseResetDate(seven["resets_at"] as? String)))
        }
        for (key, raw) in root where key.hasPrefix("seven_day_") {
            guard let window = raw as? [String: Any], let value = window["utilization"] as? NSNumber else { continue }
            let model = key.replacingOccurrences(of: "seven_day_", with: "").capitalized
            quotas.append(ClaudeQuota(kind: .sevenDayModel, key: "Semanal \(model)", usedPercent: value.doubleValue, resetAt: Self.parseResetDate(window["resets_at"] as? String)))
        }
        guard !quotas.isEmpty else { throw ClaudeUsageError.invalidResponse }
        return ClaudeUsageSnapshot(plan: root["plan"] as? String ?? "Claude Pro/Max", quotas: quotas, source: "Anthropic OAuth (Claude Code)")
    }

    // Formatadores reutilizados: criar um `ISO8601DateFormatter` é caro e esta função roda por
    // linha de log no histórico (antes eram 2 alocações por chamada). O acesso é serializado por `isoLock`.
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plainISO = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    /// The usage endpoint returns `resets_at` with fractional seconds
    /// (e.g. `2026-07-20T22:40:00.121846+00:00`), which the default `ISO8601DateFormatter`
    /// rejects. Try the fractional format first, then fall back to the plain one.
    public static func parseResetDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        isoLock.lock(); defer { isoLock.unlock() }
        return fractionalISO.date(from: string) ?? plainISO.date(from: string)
    }

    public func tokenUsage(profileDirectory: URL) -> ClaudeTokenUsage {
        let projects = profileDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return ClaudeTokenUsage(input: 0, output: 0, cacheRead: 0, cacheCreation: 0, messageCount: 0)
        }
        // Soma o total por arquivo. Arquivo inalterado (mesmo mtime + tamanho) reaproveita o total;
        // arquivo que só CRESCEU (sessão ativa, append-only) processa apenas os bytes novos, a partir
        // do offset salvo; só um arquivo reescrito/truncado é relido do início.
        var total = ClaudeTokenUsage.zero
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let signature = TokenUsageCache.Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize ?? -1)
            let previous = tokenCache.entry(for: url.path)
            if let previous, previous.signature == signature {
                total = total + previous.state.total
                continue
            }
            let state = Self.scanTokenFile(url, signature: signature, previous: previous?.state)
            tokenCache.store(state, for: url.path, signature: signature)
            total = total + state.total
        }
        return total
    }

    /// Lê e soma os tokens de um `.jsonl` de sessão (a partir do offset salvo, se o arquivo só
    /// cresceu), deduplicando mensagens repetidas.
    ///
    /// O Claude Code grava vários chunks de streaming para a MESMA mensagem, todos com
    /// `message.id` + `requestId` iguais e o mesmo `usage`. Somar linha a linha conta a mesma
    /// mensagem N vezes (observado ~2x no total real), então contamos cada `message.id:requestId`
    /// uma única vez (a última vence — os chunks são idênticos). Mesma chave do `CostUsageScanner`
    /// do CodexBar / `ccusage`; ver `UsageHistoryService.parseFile`. Logs antigos sem os dois IDs
    /// são tratados como distintos, para não descartar uso legítimo. `messageCount` passa a contar
    /// mensagens deduplicadas, não linhas.
    private static func scanTokenFile(_ url: URL, signature: TokenUsageCache.Signature, previous: TokenFileState?) -> TokenFileState {
        let head = JSONLScanner.head(of: url)
        var keyed: [String: ClaudeTokenUsage] = [:]
        var unkeyed = ClaudeTokenUsage.zero
        var offset: UInt64 = 0
        // Só retoma se o estado deduplicado ainda existe (não foi "congelado"), o arquivo não
        // encolheu e o começo é o mesmo (não foi reescrito).
        if let previous, let previousKeyed = previous.keyed, UInt64(max(0, signature.size)) >= previous.offset, head.starts(with: previous.head) {
            keyed = previousKeyed; unkeyed = previous.unkeyed; offset = previous.offset
        }
        let end = JSONLScanner.scan(url, from: offset) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] as? String == "assistant", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return }
            let entry = ClaudeTokenUsage(
                input: (usage["input_tokens"] as? NSNumber)?.intValue ?? 0,
                output: (usage["output_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheCreation: (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0,
                messageCount: 1)
            if let messageId = message["id"] as? String, let requestId = object["requestId"] as? String {
                keyed["\(messageId):\(requestId)"] = entry
            } else {
                unkeyed = unkeyed + entry
            }
        }
        let total = keyed.values.reduce(unkeyed, +)
        // Arquivos que não mudam há dias não crescem mais: descarta o mapa de dedup (RAM) e guarda
        // só o total. Se um deles voltar a crescer, é relido do início.
        let isCold = signature.modifiedAt.map { Date().timeIntervalSince($0) > TokenFileState.coldAfter } ?? false
        return TokenFileState(keyed: isCold ? nil : keyed, unkeyed: unkeyed, offset: end ?? 0, head: head, total: total)
    }

    private func accessToken(profileDirectory: URL) -> String? {
        let service = KeychainCredentials.serviceName(for: profileDirectory)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try? process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let token = root["accessToken"] as? String { return token }
        if let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String { return token }
        return nil
    }
}

/// Estado incremental de um `.jsonl`: total já somado + o necessário para retomar a leitura
/// de onde parou (offset, impressão digital do início e o mapa de deduplicação).
struct TokenFileState: Sendable {
    /// Depois de 24h sem escrita o arquivo é tratado como "frio": só o total é mantido.
    static let coldAfter: TimeInterval = 24 * 3600
    var keyed: [String: ClaudeTokenUsage]?
    var unkeyed: ClaudeTokenUsage
    var offset: UInt64
    var head: Data
    var total: ClaudeTokenUsage
}

/// Cache thread-safe de tokens por arquivo `.jsonl`, chaveado por (mtime, tamanho). Como
/// sessões são majoritariamente append-only, um refresh típico só lê os bytes novos dos poucos
/// arquivos que mudaram. Referência de longa vida mantida pelo `ClaudeUsageService`.
final class TokenUsageCache: @unchecked Sendable {
    struct Signature: Equatable { let modifiedAt: Date?; let size: Int }
    private let lock = NSLock()
    private var entries: [String: (signature: Signature, state: TokenFileState)] = [:]

    func entry(for path: String) -> (signature: Signature, state: TokenFileState)? {
        lock.lock(); defer { lock.unlock() }
        return entries[path]
    }

    func store(_ state: TokenFileState, for path: String, signature: Signature) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (signature, state)
    }
}
