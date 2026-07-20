import Foundation

public enum DesktopAppSkipReason: Equatable, Sendable { case appNotInstalled }

public enum DesktopAppSyncResult: Equatable, Sendable {
    case synced
    case skipped(DesktopAppSkipReason)
    case failed(String)
}

public actor DesktopAppActivator {
    private let client: DesktopAppClient
    public init(client: DesktopAppClient = SystemDesktopAppClient()) { self.client = client }

    public func sync(to profile: Profile) -> DesktopAppSyncResult {
        guard let bundleURL = client.locateBundle() else { return .skipped(.appNotInstalled) }
        if client.isRunning() {
            guard client.terminate(timeout: 5) else { return .failed("timed out waiting for the desktop app to quit") }
        }
        let directory = profile.desktopDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try client.launch(bundleURL: bundleURL, userDataDirectory: directory)
            return .synced
        } catch {
            return .failed("\(error)")
        }
    }
}
