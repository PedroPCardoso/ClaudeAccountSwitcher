import Foundation

/// Persistência atômica do último `CursorUsageSnapshot` em `cursor-usage.json`,
/// no mesmo diretório raiz gerenciado pelo `ProfileStore`.
public final class CursorUsageStore: @unchecked Sendable {
    public let root: URL
    public let snapshotURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.claudeaccountswitcher.cursorusagestore")

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        self.snapshotURL = root.appendingPathComponent("cursor-usage.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func load() throws -> CursorUsageSnapshot? {
        try queue.sync {
            guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
            let data = try Data(contentsOf: snapshotURL)
            return try decoder.decode(CursorUsageSnapshot.self, from: data)
        }
    }

    public func save(_ snapshot: CursorUsageSnapshot) throws {
        try queue.sync {
            let data = try encoder.encode(snapshot)
            let temporary = snapshotURL.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                _ = try fileManager.replaceItemAt(snapshotURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: snapshotURL)
            }
        }
    }
}
