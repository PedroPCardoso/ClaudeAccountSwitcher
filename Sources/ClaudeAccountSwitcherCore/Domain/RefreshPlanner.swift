import Foundation

/// Quem pediu o refresh. `scheduled` (timer) respeita os TTLs; `onDemand` (usuário abriu uma janela
/// de uso) atualiza o uso de todos os perfis e do Cursor já; `manual` (botão "Atualizar") também
/// re-checa a autenticação via CLI.
public enum RefreshScope: Sendable, Equatable { case scheduled, onDemand, manual }

/// Quanto cada fonte de dado é atualizada. O ciclo roda de minuto em minuto, mas nem tudo precisa de
/// dado novo a cada minuto — e o item mais caro (`claude auth status`, um processo do CLI de
/// ~150 MB e ~0,25 s de CPU por perfil) quase nunca muda.
public struct RefreshPolicy: Sendable, Equatable {
    /// Re-checa e-mail/organização/health via CLI com perfil saudável.
    public var authInterval: TimeInterval = 30 * 60
    /// Idem para perfil não saudável, ou quando o fetch de uso falha por token.
    public var authRetryInterval: TimeInterval = 5 * 60
    /// Perfis que não são o ativo mudam pouco; o ativo é atualizado a cada ciclo.
    public var inactiveUsageInterval: TimeInterval = 5 * 60
    /// Quebra por modelo/histórico diário do Cursor (2 RPCs a mais que o essencial).
    public var cursorDetailsInterval: TimeInterval = 10 * 60
    public init() {}
}

/// O que um ciclo de refresh precisa fazer por perfil.
public struct ProfileRefreshPlan: Sendable, Equatable {
    public let fetchUsage: Bool
    public let checkAuth: Bool
    /// Se o fetch de uso falhar por token, o CLI pode ser consultado (respeitando o intervalo de retry).
    public let authRetryAllowed: Bool
}

public enum RefreshPlanner {
    public static func plan(profile: Profile,
                            isActive: Bool,
                            scope: RefreshScope,
                            now: Date,
                            lastUsageFetch: Date?,
                            lastAuthCheck: Date?,
                            policy: RefreshPolicy = .init()) -> ProfileRefreshPlan {
        let usageAge = now.timeIntervalSince(lastUsageFetch ?? .distantPast)
        let authAge = now.timeIntervalSince(lastAuthCheck ?? .distantPast)
        let authTTL = profile.health == .ready ? policy.authInterval : policy.authRetryInterval
        return ProfileRefreshPlan(
            // Sem uso conhecido (`usage == nil`) sempre tenta: é o que popula a primeira exibição.
            fetchUsage: scope != .scheduled || isActive || profile.usage == nil || usageAge >= policy.inactiveUsageInterval,
            checkAuth: scope == .manual || authAge >= authTTL,
            authRetryAllowed: authAge >= policy.authRetryInterval)
    }

    public static func shouldFetchCursorDetails(scope: RefreshScope, now: Date, lastFetch: Date?, policy: RefreshPolicy = .init()) -> Bool {
        guard scope == .scheduled, let lastFetch else { return true }
        return now.timeIntervalSince(lastFetch) >= policy.cursorDetailsInterval
    }
}
