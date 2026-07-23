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
    private let paseoIntegration: PaseoIntegration?
    public init(store: ProfileStore, launchd: LaunchdEnvironmentClient = SystemLaunchdEnvironment(), desktopActivator: DesktopAppActivator = DesktopAppActivator(), paseoIntegration: PaseoIntegration? = nil) {
        self.store = store; self.launchd = launchd; self.desktopActivator = desktopActivator; self.paseoIntegration = paseoIntegration
    }

    public func activate(_ profile: Profile, syncDesktopApp: Bool = true) async throws -> ActivationResult {
        guard FileManager.default.fileExists(atPath: profile.directory.path) else { throw ActivationError.missingDirectory }
        // Captura o estado anterior para desfazer cada passo em caso de falha.
        let previousActive = try store.active()
        let previousRecord = try store.list().first(where: { $0.id == profile.id })
        let previousSymlinkTarget = paseoIntegration.flatMap { integration -> URL? in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: integration.activeConfigDirSymlink.path) else { return nil }
            return URL(fileURLWithPath: destination)
        }

        var didSetActive = false, didSetLaunchd = false, didUpdateSymlink = false, didSave = false
        let updated: Profile
        do {
            try store.setActive(ActiveProfile(id: profile.id, directory: profile.directory)); didSetActive = true
            try launchd.set(profile.directory.path); didSetLaunchd = true
            // Propaga o erro do symlink (antes era engolido por `try?`), senão o Paseo poderia
            // ficar apontando para a conta antiga sem qualquer aviso.
            if let paseoIntegration { try paseoIntegration.updateSymlink(to: profile.directory); didUpdateSymlink = true }
            var candidate = profile; candidate.lastUsedAt = .now; candidate.health = .ready; try store.save(candidate); didSave = true
            updated = candidate
        } catch {
            rollback(previousActive: previousActive, previousRecord: previousRecord, previousSymlinkTarget: previousSymlinkTarget,
                     didSetActive: didSetActive, didSetLaunchd: didSetLaunchd, didUpdateSymlink: didUpdateSymlink, didSave: didSave)
            throw ActivationError.rolledBack(error)
        }
        let desktopSync = syncDesktopApp ? await desktopActivator.sync(to: updated) : .skipped(.disabledOnSwitch)
        return ActivationResult(profile: updated, desktopSync: desktopSync)
    }

    /// Desfaz, na ordem inversa, apenas os passos que chegaram a ser aplicados. Best-effort:
    /// cada reversão é independente e não deve mascarar o erro original da ativação.
    private func rollback(previousActive: ActiveProfile?, previousRecord: Profile?, previousSymlinkTarget: URL?,
                          didSetActive: Bool, didSetLaunchd: Bool, didUpdateSymlink: Bool, didSave: Bool) {
        if didSave, let previousRecord { try? store.save(previousRecord) }
        if didUpdateSymlink, let previousSymlinkTarget { try? paseoIntegration?.updateSymlink(to: previousSymlinkTarget) }
        if didSetLaunchd {
            if let previousActive { try? launchd.set(previousActive.directory.path) } else { try? launchd.unset() }
        }
        if didSetActive {
            if let previousActive { try? store.setActive(previousActive) }
            else { try? FileManager.default.removeItem(at: store.activeURL) }
        }
    }
}
