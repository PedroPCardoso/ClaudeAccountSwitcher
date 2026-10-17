import Foundation

public protocol LaunchdEnvironmentClient: Sendable {
    func set(_ value: String) throws
    func unset() throws
    /// Valor atual de `CLAUDE_CONFIG_DIR` no launchd, ou `nil` se não definido.
    func get() -> String?
}

public extension LaunchdEnvironmentClient {
    func get() -> String? { nil }
}

public struct SystemLaunchdEnvironment: LaunchdEnvironmentClient {
    public init() {}
    public func set(_ value: String) throws { _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["setenv", "CLAUDE_CONFIG_DIR", value]) }
    public func get() -> String? {
        guard let result = try? ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["getenv", "CLAUDE_CONFIG_DIR"], timeout: 10) else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    public func unset() throws { _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unsetenv", "CLAUDE_CONFIG_DIR"]) }
}
