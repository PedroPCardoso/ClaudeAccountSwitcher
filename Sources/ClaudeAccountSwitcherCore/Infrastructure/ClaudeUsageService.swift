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

/// Reads the same OAuth usage endpoint used by 9router. The endpoint is a
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

    /// The usage endpoint returns `resets_at` with fractional seconds
    /// (e.g. `2026-07-20T22:40:00.121846+00:00`), which the default `ISO8601DateFormatter`
    /// rejects. Try the fractional format first, then fall back to the plain one.
    public static func parseResetDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    public func tokenUsage(profileDirectory: URL) -> ClaudeTokenUsage {
        let projects = profileDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return ClaudeTokenUsage(input: 0, output: 0, cacheRead: 0, cacheCreation: 0, messageCount: 0)
        }
        // Soma o total por arquivo, reaproveitando o cache quando o `.jsonl` não mudou
        // (mesmos mtime + tamanho). Antes, todos os arquivos eram relidos e reprocessados a
        // cada refresh de 60s, com custo crescendo indefinidamente com o histórico.
        var total = ClaudeTokenUsage.zero
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let signature = TokenUsageCache.Signature(modifiedAt: values?.contentModificationDate, size: values?.fileSize ?? -1)
            if let cached = tokenCache.usage(for: url.path, matching: signature) {
                total = total + cached
                continue
            }
            let parsed = Self.parseTokenFile(url)
            tokenCache.store(parsed, for: url.path, signature: signature)
            total = total + parsed
        }
        return total
    }

    /// Lê e soma os tokens de um único arquivo `.jsonl` de sessão.
    private static func parseTokenFile(_ url: URL) -> ClaudeTokenUsage {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return .zero
        }
        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, messages = 0
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "assistant", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
            input += (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            output += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            cacheRead += (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheCreation += (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            messages += 1
        }
        return ClaudeTokenUsage(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation, messageCount: messages)
    }

    private func accessToken(profileDirectory: URL) -> String? {
        let digest = SHA256.hash(data: Data(profileDirectory.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let service = "Claude Code-credentials-\(suffix)"
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

/// Cache thread-safe de tokens por arquivo `.jsonl`, chaveado por (mtime, tamanho). Como
/// sessões são majoritariamente append-only, um refresh típico só relê os poucos arquivos
/// que mudaram. Referência de longa vida mantida pelo `ClaudeUsageService`.
final class TokenUsageCache: @unchecked Sendable {
    struct Signature: Equatable { let modifiedAt: Date?; let size: Int }
    private let lock = NSLock()
    private var entries: [String: (signature: Signature, usage: ClaudeTokenUsage)] = [:]

    func usage(for path: String, matching signature: Signature) -> ClaudeTokenUsage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature else { return nil }
        return entry.usage
    }

    func store(_ usage: ClaudeTokenUsage, for path: String, signature: Signature) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (signature, usage)
    }
}
