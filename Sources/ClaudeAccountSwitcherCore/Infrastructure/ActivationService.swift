import Foundation

public enum ActivationError: Error { case missingDirectory, rolledBack(Error) }

public actor ActivationService {
    private let store: ProfileStore
    private let launchd: LaunchdEnvironmentClient
    public init(store: ProfileStore, launchd: LaunchdEnvironmentClient = SystemLaunchdEnvironment()) { self.store = store; self.launchd = launchd }

    public func activate(_ profile: Profile) throws -> Profile {
        guard FileManager.default.fileExists(atPath: profile.directory.path) else { throw ActivationError.missingDirectory }
        let previous = try store.active()
        do {
            try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory))
            try launchd.set(profile.directory.path)
            var updated = profile; updated.lastUsedAt = .now; updated.health = .ready; try store.save(updated)
            return updated
        } catch {
            if let previous { try? store.setActive(previous) }
            else { try? FileManager.default.removeItem(at: store.activeURL) }
            try? launchd.unset()
            throw ActivationError.rolledBack(error)
        }
    }
}
