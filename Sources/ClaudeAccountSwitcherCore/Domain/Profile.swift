import Foundation

public enum ProfileKind: String, Codable, Sendable { case claudeSubscription, anthropicConsole, custom }
public enum ProfileHealth: String, Codable, Sendable { case unknown, ready, expired }

public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var email: String?
    public var organization: String?
    public var color: String
    public var icon: String
    public var kind: ProfileKind
    public var directory: URL
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var health: ProfileHealth
    public var usage: ClaudeUsageSnapshot?

    public var desktopDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("desktop", isDirectory: true) }

    public init(id: UUID = UUID(), name: String, email: String? = nil, organization: String? = nil, color: String = "blue", icon: String = "person.crop.circle", kind: ProfileKind = .custom, directory: URL, createdAt: Date = .now, lastUsedAt: Date? = nil, health: ProfileHealth = .unknown, usage: ClaudeUsageSnapshot? = nil) {
        self.id = id; self.name = name; self.email = email; self.organization = organization; self.color = color; self.icon = icon; self.kind = kind; self.directory = directory; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.health = health; self.usage = usage
    }
}

public struct ActiveProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let directory: URL
    public let updatedAt: Date
    public init(id: UUID, directory: URL, updatedAt: Date = .now) { self.id = id; self.directory = directory; self.updatedAt = updatedAt }

    private enum CodingKeys: String, CodingKey { case id, directory, updatedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let rawDirectory = try container.decode(String.self, forKey: .directory)
        if let url = URL(string: rawDirectory), url.isFileURL { directory = url }
        else { directory = URL(fileURLWithPath: rawDirectory) }
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(directory.path, forKey: .directory)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
