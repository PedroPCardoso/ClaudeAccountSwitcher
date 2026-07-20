import Foundation

public enum ProfileKind: String, Codable, Sendable { case claudeSubscription, anthropicConsole, custom }
public enum ProfileHealth: String, Codable, Sendable { case unknown, ready, expired, unavailable }

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

    public init(id: UUID = UUID(), name: String, email: String? = nil, organization: String? = nil, color: String = "blue", icon: String = "person.crop.circle", kind: ProfileKind = .custom, directory: URL, createdAt: Date = .now, lastUsedAt: Date? = nil, health: ProfileHealth = .unknown) {
        self.id = id; self.name = name; self.email = email; self.organization = organization; self.color = color; self.icon = icon; self.kind = kind; self.directory = directory; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.health = health
    }
}

public struct ActiveProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let directory: URL
    public let updatedAt: Date
    public init(id: UUID, directory: URL, updatedAt: Date = .now) { self.id = id; self.directory = directory; self.updatedAt = updatedAt }
}
