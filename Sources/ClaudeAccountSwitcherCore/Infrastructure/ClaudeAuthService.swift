import Foundation

public struct AuthStatus: Sendable, Equatable {
    public let isAuthenticated: Bool
    public let email: String?
    public let organization: String?
    public let baseURL: String?
    public let kind: ProfileKind
}

public enum ClaudeAuthError: Error { case invalidStatus, loginFailed(String) }

public struct ClaudeAuthService: Sendable {
    public let locator: ClaudeLocator
    public let runner: ProcessRunner
    public init(locator: ClaudeLocator, runner: ProcessRunner = .init()) { self.locator = locator; self.runner = runner }

    public func status(profileDirectory: URL) throws -> AuthStatus {
        let result = try runner.run(executable: locator.locate(), arguments: ["auth", "status", "--json"], environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path], timeout: 30)
        guard let data = result.stdout.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeAuthError.invalidStatus }
        let authenticated = (raw["loggedIn"] as? Bool) ?? (raw["isAuthenticated"] as? Bool) ?? raw["authToken"] != nil
        let email = raw["email"] as? String
        let organization = raw["organization"] as? String ?? raw["organizationName"] as? String
        let baseURL = raw["anthropicBaseUrl"] as? String ?? raw["baseUrl"] as? String
        let kind: ProfileKind = baseURL == nil ? .claudeSubscription : .custom
        return AuthStatus(isAuthenticated: authenticated, email: email, organization: organization, baseURL: baseURL, kind: kind)
    }

    public func login(profileDirectory: URL, kind: ProfileKind, email: String? = nil) throws {
        let mode = kind == .anthropicConsole ? "--console" : "--claudeai"
        var args = ["auth", "login", mode]; if let email, !email.isEmpty { args += ["--email", email] }
        // Login abre o browser e aguarda o fluxo OAuth; timeout generoso evita pendurar
        // a app para sempre caso o CLI trave, sem cortar uma interação legítima do usuário.
        do { _ = try runner.run(executable: locator.locate(), arguments: args, environment: ["CLAUDE_CONFIG_DIR": profileDirectory.path], timeout: 300) }
        catch let ProcessRunnerError.failed(result) { throw ClaudeAuthError.loginFailed(result.stderr) }
    }
}
