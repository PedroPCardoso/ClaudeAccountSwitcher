import Foundation

public enum StoreError: Error, Equatable { case corruptState(URL), duplicateProfile(UUID), missingProfile(UUID), unmanagedProfile(URL) }

public final class ProfileStore: @unchecked Sendable {
    public let root: URL
    public let profilesDirectory: URL
    public let metadataURL: URL
    public let activeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    // Serializes read-modify-write access to profiles.json / active-profile.json. save()/remove()/
    // setActive() each run as a single critical section on this queue so a concurrent background
    // refresh (Task.detached in MenuBarController) can never race a foreground rename/activate and
    // silently drop one of the writes (see GitHub issue #1). Private *Locked methods below assume
    // the queue is already held and must never re-enter it.
    private let queue = DispatchQueue(label: "com.claudeaccountswitcher.profilestore")

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root; self.fileManager = fileManager
        profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
        metadataURL = root.appendingPathComponent("profiles.json")
        activeURL = root.appendingPathComponent("active-profile.json")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func list() throws -> [Profile] {
        try queue.sync { try listLocked() }
    }

    public func save(_ profile: Profile) throws {
        try queue.sync {
            var profiles = try listLocked()
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else { profiles.append(profile) }
            try atomicWrite(try encoder.encode(profiles), to: metadataURL)
        }
    }

    public func remove(_ profile: Profile) throws {
        try queue.sync {
            let managedRoot = profilesDirectory.standardizedFileURL.path
            let profilePath = profile.directory.standardizedFileURL.path
            guard profilePath.hasPrefix(managedRoot + "/") else { throw StoreError.unmanagedProfile(profile.directory) }
            let existing = try listLocked()
            guard existing.contains(where: { $0.id == profile.id }) else { throw StoreError.missingProfile(profile.id) }
            let profiles = existing.filter { $0.id != profile.id }
            try atomicWrite(try encoder.encode(profiles), to: metadataURL)
            if fileManager.fileExists(atPath: profile.directory.path) { try fileManager.removeItem(at: profile.directory) }
            if (try activeLocked()?.id) == profile.id, fileManager.fileExists(atPath: activeURL.path) { try fileManager.removeItem(at: activeURL) }
        }
    }

    public func active() throws -> ActiveProfile? {
        try queue.sync { try activeLocked() }
    }

    public func setActive(_ active: ActiveProfile) throws {
        try queue.sync { try setActiveLocked(active) }
    }

    private func listLocked() throws -> [Profile] {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return [] }
        do { return try decoder.decode([Profile].self, from: Data(contentsOf: metadataURL)) }
        catch { throw StoreError.corruptState(metadataURL) }
    }

    private func activeLocked() throws -> ActiveProfile? {
        guard fileManager.fileExists(atPath: activeURL.path) else { return nil }
        let data = try Data(contentsOf: activeURL)
        if let active = try? decoder.decode(ActiveProfile.self, from: data) { return active }

        // Older releases persisted only the active id. Resolve its directory from
        // the profile metadata so upgrading does not strand the terminal launcher.
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawID = raw["id"] as? String,
            let id = UUID(uuidString: rawID),
            let profile = try? listLocked().first(where: { $0.id == id })
        else { throw StoreError.corruptState(activeURL) }
        let migrated = ActiveProfile(id: profile.id, directory: profile.directory)
        try setActiveLocked(migrated)
        return migrated
    }

    private func setActiveLocked(_ active: ActiveProfile) throws { try atomicWrite(try encoder.encode(active), to: activeURL) }

    public func createManagedDirectory(id: UUID) throws -> URL {
        let directory = profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("config", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) { _ = try fileManager.replaceItemAt(destination, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: destination) }
    }
}
