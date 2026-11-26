import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// Wrapper mínimo sobre a libsqlite3 do sistema (sem dependência externa). Não é thread-safe:
/// cada chamador abre, usa e fecha a sua própria conexão numa única thread.
final class SQLiteDatabase {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let status = sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: status, message: message)
        }
        handle = db
        // App e `cas` podem gravar ao mesmo tempo: espera o lock em vez de falhar na hora.
        sqlite3_busy_timeout(db, 15_000)
    }

    deinit { sqlite3_close(handle) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError(code: status, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw error(status) }
        return SQLiteStatement(statement, database: self)
    }

    /// Executa `body` dentro de `BEGIN IMMEDIATE` (lock de escrita já no início, para que o estado
    /// lido dentro da transação não fique velho por causa de outro processo); rollback se lançar.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func error(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }
}

/// Destrutor "transient": o SQLite copia o buffer na hora do bind.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    /// Associa os valores aos `?` em ordem. Aceita `String`, `Int`, `Int64`, `Double`, `Bool`,
    /// `Data` e `nil`.
    @discardableResult
    func bind(_ values: [Any?]) throws -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case nil: status = sqlite3_bind_null(statement, index)
            case let v as String: status = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case let v as Int: status = sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: status = sqlite3_bind_int64(statement, index, v)
            case let v as UInt64: status = sqlite3_bind_int64(statement, index, Int64(clamping: v))
            case let v as Double: status = sqlite3_bind_double(statement, index, v)
            case let v as Bool: status = sqlite3_bind_int(statement, index, v ? 1 : 0)
            case let v as Data:
                status = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, index, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(raw.count), SQLITE_TRANSIENT)
                }
            default: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw database.error(status) }
        }
        return self
    }

    /// Avança uma linha; `true` enquanto houver resultado.
    func step() throws -> Bool {
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.error(status)
        }
    }

    /// Executa até o fim (INSERT/UPDATE).
    func run(_ values: [Any?] = []) throws {
        try bind(values)
        while try step() {}
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
