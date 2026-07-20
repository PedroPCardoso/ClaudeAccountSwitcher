import Foundation

public enum ActivationError: Error { case missingDirectory, rolledBack(Error) }

public struct ActivationResult: Sendable, Equatable {
    public let profile: Profile
    public let desktopSync: DesktopAppSyncResult
}

public actor ActivationService {
    private let store: ProfileStore
    private let launchd: LaunchdEnvironmentClient
    private let desktopActivator: DesktopAppActivator
    public init(store: ProfileStore, launchd: LaunchdEnvironmentClient = SystemLaunchdEnvironment(), desktopActivator: DesktopAppActivator = DesktopAppActivator()) {
        self.store = store; self.launchd = launchd; self.desktopActivator = desktopActivator
    }

    public func activate(_ profile: Profile, syncDesktopApp: Bool = true) async throws -> ActivationResult {
        guard FileManager.default.fileExists(atPath: profile.directory.path) else { throw ActivationError.missingDirectory }
        let previous = try store.active()
        let updated: Profile
        do {
            try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
            try launchd.set(profile.directory.path)
            var candidate = profile; candidate.lastUsedAt = .now; candidate.health = .ready; try store.save(candidate)
            updated = candidate
        } catch {
            if let previous { try? store.setActive(previous) }
            else { try? FileManager.default.removeItem(at: store.activeURL) }
            try? launchd.unset()
            throw ActivationError.rolledBack(error)
        }
        let desktopSync = syncDesktopApp ? await desktopActivator.sync(to: updated) : .skipped(.disabledOnSwitch)
        return ActivationResult(profile: updated, desktopSync: desktopSync)
    }
}
