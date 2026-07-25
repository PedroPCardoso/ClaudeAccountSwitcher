import Foundation

public enum CursorUsageError: Error, Equatable {
    case credentialsUnavailable
    case tokenExpired
    case invalidResponse
    case unauthorized
}

/// Busca uso do Cursor via Connect-RPC em `api2.cursor.sh`. Reusa `UsageTransport` /
/// `UsageRetryPolicy` do `ClaudeUsageService`. Degradação graciosa: se o agregado ou o
/// histórico diário falharem, ainda retorna o snapshot com `planUsage`.
public struct CursorUsageService: Sendable {
    private let transport: UsageTransport
    private let retry: UsageRetryPolicy
    private let credentialProvider: @Sendable () throws -> CursorCredentials

    private static let baseURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!

    public init(
        retry: UsageRetryPolicy = .init(),
        transport: @escaping UsageTransport = { try await URLSession.shared.data(for: $0) },
        credentialProvider: (@Sendable () throws -> CursorCredentials)? = nil
    ) {
        self.retry = retry
        self.transport = transport
        if let credentialProvider {
            self.credentialProvider = credentialProvider
        } else {
            let store = CursorCredentialStore()
            self.credentialProvider = { try store.credentials() }
        }
    }

    public func fetch() async throws -> CursorUsageSnapshot {
        let credentials: CursorCredentials
        do {
            credentials = try credentialProvider()
        } catch CursorCredentialError.tokenExpired {
            throw CursorUsageError.tokenExpired
        } catch {
            throw CursorUsageError.credentialsUnavailable
        }
        if credentials.isExpired { throw CursorUsageError.tokenExpired }

        let periodData = try await post(method: "GetCurrentPeriodUsage", body: [:], token: credentials.accessToken)
        guard let planUsage = Self.parsePeriodUsage(periodData) else {
            throw CursorUsageError.invalidResponse
        }

        let startMs = Int64(planUsage.billingCycleStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(planUsage.billingCycleEnd.timeIntervalSince1970 * 1000)

        var models: [CursorModelUsage] = []
        if let aggData = try? await post(
            method: "GetAggregatedUsageEvents",
            body: ["startDate": String(startMs), "endDate": String(endMs)],
            token: credentials.accessToken
        ) {
            models = Self.parseAggregated(aggData)
        }

        var daily: [CursorDailySpend] = []
        if let dailyData = try? await post(
            method: "GetDailySpendByCategory",
            body: [
                "periodStartMs": String(startMs),
                "periodEndMs": String(endMs),
                "groupBy": 1
            ],
            token: credentials.accessToken
        ) {
            daily = Self.parseDaily(dailyData)
        }

        return CursorUsageSnapshot(
            fetchedAt: .now,
            email: credentials.email,
            plan: credentials.membershipType,
            planUsage: planUsage,
            models: models,
            daily: daily,
            source: "Cursor Dashboard API")
    }

    // MARK: - HTTP

    private func post(method: String, body: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetchWithRetry(request)
    }

    private func fetchWithRetry(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse else { throw CursorUsageError.invalidResponse }
                if http.statusCode == 401 || http.statusCode == 403 { throw CursorUsageError.unauthorized }
                if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    if attempt < retry.maxAttempts { try await backoff(attempt); continue }
                    throw CursorUsageError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else { throw CursorUsageError.invalidResponse }
                return data
            } catch let error as CursorUsageError {
                throw error
            } catch {
                if attempt < retry.maxAttempts { try await backoff(attempt); continue }
                throw error
            }
        }
    }

    private func backoff(_ attempt: Int) async throws {
        guard retry.baseDelay > 0 else { return }
        let exponential = retry.baseDelay * pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0...(exponential * 0.25))
        try await Task.sleep(nanoseconds: UInt64((exponential + jitter) * 1_000_000_000))
    }

    // MARK: - Parsing (público para testes)

    public static func parsePeriodUsage(_ data: Data) -> CursorPlanUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let start = dateFromMillis(root["billingCycleStart"])
        let end = dateFromMillis(root["billingCycleEnd"])
        guard let start, let end else { return nil }
        let plan = root["planUsage"] as? [String: Any] ?? [:]
        let totalSpend = doubleValue(plan["totalSpend"]) ?? 0
        let includedSpend = doubleValue(plan["includedSpend"]) ?? totalSpend
        let limit = doubleValue(plan["limit"]) ?? 0
        let remaining = doubleValue(plan["remaining"]) ?? max(0, limit - totalSpend)
        // Espelha a página "Included in Pro": Cursor Models = autoPercentUsed,
        // Other Models = apiPercentUsed. Não usar totalPercentUsed / spend÷limit —
        // ver comentário em CursorPlanUsage.
        return CursorPlanUsage(
            totalSpendCents: totalSpend,
            includedSpendCents: includedSpend,
            limitCents: limit,
            remainingCents: remaining,
            billingCycleStart: start,
            billingCycleEnd: end,
            cursorModelsPercent: doubleValue(plan["autoPercentUsed"]),
            otherModelsPercent: doubleValue(plan["apiPercentUsed"]))
    }

    public static func parseAggregated(_ data: Data) -> [CursorModelUsage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aggregations = root["aggregations"] as? [[String: Any]] else { return [] }
        return aggregations.compactMap { row in
            guard let model = row["modelIntent"] as? String else { return nil }
            return CursorModelUsage(
                modelIntent: model,
                input: intValue(row["inputTokens"]) ?? 0,
                output: intValue(row["outputTokens"]) ?? 0,
                cacheWrite: intValue(row["cacheWriteTokens"]) ?? 0,
                cacheRead: intValue(row["cacheReadTokens"]) ?? 0,
                costCents: doubleValue(row["totalCents"]) ?? 0)
        }
    }

    public static func parseDaily(_ data: Data) -> [CursorDailySpend] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["dailySpend"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let day = dateFromMillis(row["day"]),
                  let category = row["category"] as? String else { return nil }
            return CursorDailySpend(
                day: day,
                modelIntent: category,
                spendCents: doubleValue(row["spendCents"]) ?? 0,
                totalTokens: intValue(row["totalTokens"]) ?? 0)
        }
        .sorted { $0.day < $1.day }
    }

    // MARK: - JSON helpers

    /// Aceita Int, Double, String (a API manda timestamps e tokens como string às vezes).
    private static func dateFromMillis(_ raw: Any?) -> Date? {
        guard let ms = int64Value(raw) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static func int64Value(_ raw: Any?) -> Int64? {
        switch raw {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        default: return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        int64Value(raw).map { Int($0) }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }
}
