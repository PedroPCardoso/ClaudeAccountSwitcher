import Foundation

public enum StoreError: Error, Equatable { case corruptState(URL), duplicateProfile(UUID), missingProfile(UUID) }

public final class ProfileStore: @unchecked Sendable {
    public let root: URL
    public let profilesDirectory: URL
    public let metadataURL: URL
    public let activeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        guard fileManager.fileExists(atPath: metadataURL.path) else { return [] }
        do { return try decoder.decode([Profile].self, from: Data(contentsOf: metadataURL)) }
        catch { throw StoreError.corruptState(metadataURL) }
    }

    public func save(_ profile: Profile) throws {
        var profiles = try list()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try atomicWrite(try encoder.encode(profiles), to: metadataURL)
    }

    public func remove(_ profile: Profile) throws {
        let profiles = try list().filter { $0.id != profile.id }
        try atomicWrite(try encoder.encode(profiles), to: metadataURL)
    }

    public func active() throws -> ActiveProfile? {
        guard fileManager.fileExists(atPath: activeURL.path) else { return nil }
        do { return try decoder.decode(ActiveProfile.self, from: Data(contentsOf: activeURL)) }
        catch { throw StoreError.corruptState(activeURL) }
    }

    public func setActive(_ active: ActiveProfile) throws { try atomicWrite(try encoder.encode(active), to: activeURL) }

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
