import Foundation
import SQLite3

public struct CursorCredentials: Sendable, Equatable {
    public let accessToken: String
    public let email: String?
    public let membershipType: String?
    public let workosId: String?

    public init(accessToken: String, email: String? = nil, membershipType: String? = nil, workosId: String? = nil) {
        self.accessToken = accessToken
        self.email = email
        self.membershipType = membershipType
        self.workosId = workosId
    }

    /// `true` when the JWT `exp` claim is in the past (or unreadable → treat as not expired
    /// so the API can still reject with 401 and we re-read).
    public var isExpired: Bool {
        guard let exp = Self.jwtExpiration(accessToken) else { return false }
        return exp <= Date()
    }

    /// Decodes the `exp` claim from a HS256 JWT without verifying the signature.
    public static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - payload.count % 4
        if pad < 4 { payload += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

public enum CursorCredentialError: Error, Equatable {
    case databaseNotFound
    case databaseUnreadable
    case tokenMissing
    case tokenExpired
}

/// Lê as credenciais de sessão do Cursor a partir do `state.vscdb` (SQLite).
/// Cacheia em memória — o banco tem centenas de MB e o JWT dura ~2 meses.
public final class CursorCredentialStore: @unchecked Sendable {
    private let databaseURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cached: CursorCredentials?

    public init(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.databaseURL = databaseURL ?? home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        self.fileManager = fileManager
    }

    public func credentials() throws -> CursorCredentials {
        lock.lock(); defer { lock.unlock() }
        if let cached {
            if cached.isExpired { throw CursorCredentialError.tokenExpired }
            return cached
        }
        let fresh = try readFromDatabase()
        if fresh.isExpired { throw CursorCredentialError.tokenExpired }
        cached = fresh
        return fresh
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }

    private func readFromDatabase() throws -> CursorCredentials {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw CursorCredentialError.databaseNotFound
        }
        // Tenta immutable=1 (não precisa de WAL). Se falhar (banco locked), copia
        // state.vscdb + -wal + -shm para um temp e abre a cópia.
        if let result = try? query(at: databaseURL, immutable: true) {
            return result
        }
        return try queryViaCopy()
    }

    private func queryViaCopy() throws -> CursorCredentials {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("cas-cursor-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("state.vscdb")
        try fileManager.copyItem(at: databaseURL, to: dest)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: side.path) {
                try? fileManager.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix))
            }
        }
        return try query(at: dest, immutable: false)
    }

    private func query(at url: URL, immutable: Bool) throws -> CursorCredentials {
        var db: OpaquePointer?
        let path: String
        if immutable {
            // URI form: file:/path?immutable=1
            path = "file:\(url.path)?immutable=1"
        } else {
            path = url.path
        }
        let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw CursorCredentialError.databaseUnreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT key, value FROM ItemTable
        WHERE key IN (
          'cursorAuth/accessToken',
          'cursorAuth/cachedEmail',
          'cursorAuth/stripeMembershipType',
          'glass.lastSignedInAuthId'
        )
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CursorCredentialError.databaseUnreadable
        }
        defer { sqlite3_finalize(statement) }

        var token: String?
        var email: String?
        var membership: String?
        var workosId: String?

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyPtr)
            let value: String?
            if sqlite3_column_type(statement, 1) == SQLITE_TEXT, let v = sqlite3_column_text(statement, 1) {
                value = String(cString: v)
            } else if sqlite3_column_type(statement, 1) == SQLITE_BLOB {
                let bytes = sqlite3_column_blob(statement, 1)
                let count = Int(sqlite3_column_bytes(statement, 1))
                if let bytes, count > 0 {
                    value = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
                } else {
                    value = nil
                }
            } else {
                value = nil
            }
            switch key {
            case "cursorAuth/accessToken": token = value
            case "cursorAuth/cachedEmail": email = value
            case "cursorAuth/stripeMembershipType": membership = value
            case "glass.lastSignedInAuthId": workosId = value
            default: break
            }
        }

        guard let accessToken = token, !accessToken.isEmpty else {
            throw CursorCredentialError.tokenMissing
        }
        return CursorCredentials(
            accessToken: accessToken,
            email: email,
            membershipType: membership,
            workosId: workosId)
    }
}
