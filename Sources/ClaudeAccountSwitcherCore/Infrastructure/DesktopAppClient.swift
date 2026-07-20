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
    public init() {}

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
