import Foundation

public enum DesktopAppSkipReason: Equatable, Sendable { case appNotInstalled, disabledOnSwitch }

public enum DesktopAppSyncResult: Equatable, Sendable {
    case synced
    case skipped(DesktopAppSkipReason)
    case failed(String)
}

public actor DesktopAppActivator {
    private let client: DesktopAppClient
    /// Espera generosa pelo encerramento gracioso: o Electron precisa fechar janelas e dar flush
    /// em LevelDB/SQLite. 5 s era curto o bastante para cair no `forceTerminate` com frequência.
    public static let defaultQuitTimeout: TimeInterval = 20
    private let quitTimeout: TimeInterval
    public init(client: DesktopAppClient = SystemDesktopAppClient(), quitTimeout: TimeInterval = DesktopAppActivator.defaultQuitTimeout) { self.client = client; self.quitTimeout = quitTimeout }

    public func sync(to profile: Profile) -> DesktopAppSyncResult {
        guard let bundleURL = client.locateBundle() else { return .skipped(.appNotInstalled) }
        if client.isRunning() {
            guard client.terminate(timeout: quitTimeout) else { return .failed("timed out waiting for the desktop app to quit; close it manually and switch again") }
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
