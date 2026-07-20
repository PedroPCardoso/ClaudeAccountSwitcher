import Foundation

public protocol LaunchdEnvironmentClient: Sendable {
    func set(_ value: String) throws
    func unset() throws
}

public struct SystemLaunchdEnvironment: LaunchdEnvironmentClient {
    public init() {}
    public func set(_ value: String) throws { _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["setenv", "CLAUDE_CONFIG_DIR", value]) }
    public func unset() throws { _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unsetenv", "CLAUDE_CONFIG_DIR"]) }
}
