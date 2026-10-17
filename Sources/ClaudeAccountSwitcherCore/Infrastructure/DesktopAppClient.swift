import AppKit
import Foundation

public protocol DesktopAppClient: Sendable {
    func locateBundle() -> URL?
    func isRunning() -> Bool
    func terminate(timeout: TimeInterval) -> Bool
    func launch(bundleURL: URL, userDataDirectory: URL) throws
}

public struct SystemDesktopAppClient: DesktopAppClient {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// Se o app não fechar dentro do timeout, só mata à força quando esta política permitir.
    /// Padrão: nunca — `forceTerminate` no meio de uma escrita em `Cookies` (SQLite) ou
    /// `Local Storage/leveldb` pode corromper a sessão do app nativo; melhor falhar e pedir
    /// para fechar manualmente.
    private let allowsForceTerminate: @Sendable () -> Bool
    public init(allowsForceTerminate: @escaping @Sendable () -> Bool = { false }) { self.allowsForceTerminate = allowsForceTerminate }

    public func locateBundle() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    public func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func terminate(timeout: TimeInterval) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        if waitUntilTerminated(within: timeout) { return true }
        guard allowsForceTerminate() else { return false }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).forEach { $0.forceTerminate() }
        return waitUntilTerminated(within: 2)
    }

    private func waitUntilTerminated(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    public func launch(bundleURL: URL, userDataDirectory: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--user-data-dir=\(userDataDirectory.path)"]
        configuration.createsNewApplicationInstance = true
        let semaphore = DispatchSemaphore(value: 0)
        let errorCapture = ErrorCapture()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            errorCapture.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let launchError = errorCapture.error { throw launchError }
    }

    private final class ErrorCapture: @unchecked Sendable {
        var error: Error?
    }
}
