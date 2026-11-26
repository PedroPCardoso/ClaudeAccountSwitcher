import Foundation

/// Cópia local (SQLite) de todas as sessões do Claude Code de todos os perfis.
///
/// Por que existe: o CLI apaga transcrições com mais de `cleanupPeriodDays` (30 dias por padrão),
/// e um `.jsonl` corrompido ou reescrito perde a conversa. Aqui cada linha de cada `.jsonl` em
/// `projects/` (incluindo subagentes) é guardada em blocos de ~1 MB comprimidos com lzfse (~5×;
/// comprimir linha a linha dava só ~2×), o que permite reconstruir o arquivo byte a byte
/// (`restore`), e as mensagens viram tabelas consultáveis por SQL e por busca de texto (FTS5).
///
/// Regras:
/// - incremental: por arquivo guarda offset + impressão digital do início (como o `JSONLScanner`);
///   um arquivo que só cresceu lê só os bytes novos;
/// - nada é apagado nem sobrescrito: arquivo reescrito/encolhido vira uma nova `revision` (a antiga
///   fica com `superseded_at`), arquivo removido do disco ganha `deleted_at`;
/// - cada arquivo é processado numa transação `BEGIN IMMEDIATE`, então o app e o `cas sync` podem
///   rodar ao mesmo tempo sem duplicar linhas.
public struct SessionArchive: Sendable {
    public static let fileName = "sessions.db"
    static let schemaVersion: Int32 = 1

    public let databaseURL: URL

    public init(databaseURL: URL) { self.databaseURL = databaseURL }

    /// Banco padrão dentro do diretório raiz gerenciado do app.
    public init(appSupport: URL) { self.init(databaseURL: appSupport.appendingPathComponent(Self.fileName)) }

    public struct SyncReport: Equatable, Sendable {
        public var filesSeen = 0
        public var filesUpdated = 0
        public var linesAdded = 0
        public var revisionsCreated = 0
        public var filesMarkedDeleted = 0
        public var errors: [String] = []
    }

    // MARK: - Schema

    func open(readOnly: Bool = false) throws -> SQLiteDatabase {
        if !readOnly {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let db = try SQLiteDatabase(url: databaseURL, readOnly: readOnly)
        if !readOnly { try migrate(db) }
        return db
    }

    private func migrate(_ db: SQLiteDatabase) throws {
        // Statement em escopo próprio: enquanto vivo ele mantém uma leitura aberta, e o SQLite
        // recusa trocar para WAL "de dentro de uma transação".
        let version: Int32 = try {
            let query = try db.prepare("PRAGMA user_version")
            return try query.step() ? Int32(query.int(0)) : 0
        }()
        // WAL: dá para consultar com `sqlite3` enquanto o app grava.
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        guard version < Self.schemaVersion else { return }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS profiles(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT, directory TEXT NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS files(
          id INTEGER PRIMARY KEY,
          profile_id TEXT NOT NULL,
          rel_path TEXT NOT NULL,
          project_slug TEXT NOT NULL,
          session_id TEXT NOT NULL,
          parent_session_id TEXT,
          revision INTEGER NOT NULL DEFAULT 0,
          head BLOB NOT NULL DEFAULT x'',
          byte_offset INTEGER NOT NULL DEFAULT 0,
          line_count INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mtime REAL NOT NULL DEFAULT 0,
          first_seen_at REAL NOT NULL,
          last_synced_at REAL NOT NULL,
          superseded_at REAL,
          deleted_at REAL,
          UNIQUE(profile_id, rel_path, revision));
        CREATE INDEX IF NOT EXISTS files_session ON files(session_id);
        CREATE INDEX IF NOT EXISTS files_parent ON files(parent_session_id);
        -- Bytes crus do .jsonl, em blocos de até ~1 MB terminados em fim de linha. Concatenar os
        -- blocos de um arquivo em ordem de start_offset devolve o arquivo exato.
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY,
          file_id INTEGER NOT NULL REFERENCES files(id),
          start_offset INTEGER NOT NULL,
          end_offset INTEGER NOT NULL,
          codec INTEGER NOT NULL,          -- 0 = bytes crus, 1 = lzfse
          data BLOB NOT NULL,
          UNIQUE(file_id, start_offset));
        CREATE TABLE IF NOT EXISTS messages(
          id INTEGER PRIMARY KEY,
          file_id INTEGER NOT NULL REFERENCES files(id),
          line_no INTEGER NOT NULL,
          uuid TEXT, type TEXT NOT NULL, timestamp TEXT, cwd TEXT, git_branch TEXT,
          is_sidechain INTEGER NOT NULL DEFAULT 0,
          model TEXT, message_id TEXT, request_id TEXT,
          input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
          text TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS messages_file ON messages(file_id, line_no);
        CREATE INDEX IF NOT EXISTS messages_time ON messages(timestamp);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          text, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        -- Visões prontas para `cas db`: só a revisão atual de cada arquivo.
        CREATE VIEW IF NOT EXISTS v_messages AS
          SELECT m.*, f.profile_id, p.name AS profile_name, f.session_id, f.parent_session_id,
                 COALESCE(f.parent_session_id, f.session_id) AS resume_id, f.project_slug, f.deleted_at
          FROM messages m JOIN files f ON f.id = m.file_id LEFT JOIN profiles p ON p.id = f.profile_id
          WHERE f.superseded_at IS NULL;
        CREATE VIEW IF NOT EXISTS v_sessions AS
          SELECT f.profile_id, p.name AS profile_name, f.session_id, f.project_slug,
                 MIN(m.timestamp) AS started_at, MAX(m.timestamp) AS last_message_at,
                 COUNT(m.id) AS messages, MAX(m.cwd) AS cwd, f.deleted_at, f.rel_path
          FROM files f LEFT JOIN profiles p ON p.id = f.profile_id LEFT JOIN messages m ON m.file_id = f.id
          WHERE f.superseded_at IS NULL AND f.parent_session_id IS NULL
          GROUP BY f.id;
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }

    // MARK: - Sync

    private struct FileState {
        var id: Int64
        var revision: Int
        var head: Data
        var offset: UInt64
        var lineCount: Int
        var size: UInt64
        var mtime: Double
        var deleted: Bool
    }

    /// Copia para o banco tudo o que mudou nos perfis desde a última chamada.
    @discardableResult
    public func sync(profiles: [Profile], now: Date = .now) throws -> SyncReport {
        let db = try open()
        var report = SyncReport()
        for profile in profiles {
            autoreleasepool {
                do { try sync(profile: profile, db: db, now: now, report: &report) }
                catch { report.errors.append("\(profile.name): \(error)") }
            }
        }
        return report
    }

    private func sync(profile: Profile, db: SQLiteDatabase, now: Date, report: inout SyncReport) throws {
        let profileID = profile.id.uuidString
        try db.prepare("""
        INSERT INTO profiles(id, name, email, directory, updated_at) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, email=excluded.email, directory=excluded.directory, updated_at=excluded.updated_at
        """).run([profileID, profile.name, profile.email, profile.directory.path, now.timeIntervalSince1970])

        let projects = profile.directory.appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        // Sem a pasta (perfil novo ou volume fora do ar) não marca nada como apagado.
        guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        let known = try currentStates(db: db, profileID: profileID)
        var seen = Set<String>()
        let basePath = profile.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(basePath + "/") else { continue }
            let relative = String(fullPath.dropFirst(basePath.count + 1))
            guard let location = SessionFileLocation.parse(relativePath: relative) else { continue }
            seen.insert(relative)
            report.filesSeen += 1
            let size = UInt64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            // Atalho sem transação: nada mudou desde a última cópia.
            if let state = known[relative], !state.deleted, state.size == size, state.mtime == mtime, state.offset == size { continue }
            do {
                try autoreleasepool {
                    try syncFile(url: url, location: location, profileID: profileID, size: size, mtime: mtime, db: db, now: now, report: &report)
                }
            } catch {
                report.errors.append("\(relative): \(error)")
            }
        }

        let missing = known.filter { !$0.value.deleted && !seen.contains($0.key) }
        if !missing.isEmpty {
            let mark = try db.prepare("UPDATE files SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL")
            for state in missing.values { try mark.run([now.timeIntervalSince1970, state.id]) }
            report.filesMarkedDeleted += missing.count
        }
    }

    private func currentStates(db: SQLiteDatabase, profileID: String, relativePath: String? = nil) throws -> [String: FileState] {
        var sql = """
        SELECT rel_path, id, revision, head, byte_offset, line_count, size, mtime, deleted_at IS NOT NULL
        FROM files WHERE profile_id = ? AND superseded_at IS NULL
        """
        var values: [Any?] = [profileID]
        if let relativePath { sql += " AND rel_path = ?"; values.append(relativePath) }
        let query = try db.prepare(sql)
        try query.bind(values)
        var states: [String: FileState] = [:]
        while try query.step() {
            guard let path = query.string(0) else { continue }
            states[path] = FileState(id: query.int(1), revision: Int(query.int(2)), head: query.data(3),
                                     offset: UInt64(max(0, query.int(4))), lineCount: Int(query.int(5)),
                                     size: UInt64(max(0, query.int(6))), mtime: query.double(7), deleted: query.int(8) != 0)
        }
        return states
    }

    private func syncFile(url: URL, location: SessionFileLocation, profileID: String, size: UInt64, mtime: Double,
                          db: SQLiteDatabase, now: Date, report: inout SyncReport) throws {
        try db.transaction {
            // Relido dentro do lock: outro processo pode ter copiado este arquivo há pouco.
            let previous = try currentStates(db: db, profileID: profileID, relativePath: location.relativePath)[location.relativePath]
            let head = JSONLScanner.head(of: url)
            var fileID: Int64
            var offset: UInt64 = 0
            var lineNumber = 0
            if let previous, head.starts(with: previous.head), size >= previous.offset {
                fileID = previous.id
                offset = previous.offset
                lineNumber = previous.lineCount
            } else {
                if let previous {
                    try db.prepare("UPDATE files SET superseded_at = ? WHERE id = ?").run([now.timeIntervalSince1970, previous.id])
                    report.revisionsCreated += 1
                }
                try db.prepare("""
                INSERT INTO files(profile_id, rel_path, project_slug, session_id, parent_session_id, revision, first_seen_at, last_synced_at)
                VALUES(?,?,?,?,?,?,?,?)
                """).run([profileID, location.relativePath, location.projectSlug, location.sessionID, location.parentSessionID,
                          (previous?.revision ?? -1) + 1, now.timeIntervalSince1970, now.timeIntervalSince1970])
                fileID = db.lastInsertRowID
            }

            let insertChunk = try db.prepare("INSERT INTO chunks(file_id, start_offset, end_offset, codec, data) VALUES(?,?,?,?,?)")
            let insertMessage = try db.prepare("""
            INSERT INTO messages(file_id, line_no, uuid, type, timestamp, cwd, git_branch, is_sidechain, model, message_id, request_id,
                                 input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, text)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            let insertFTS = try db.prepare("INSERT INTO messages_fts(rowid, text) VALUES(?, ?)")
            var failure: Error?
            var added = 0
            // Bytes exatos das linhas lidas, acumulados até ~1 MB por bloco.
            var buffer = Data()
            var bufferStart = offset
            var position = offset
            func flush() throws {
                guard !buffer.isEmpty else { return }
                let (codec, payload) = Self.encode(buffer)
                try insertChunk.run([fileID, bufferStart, bufferStart + UInt64(buffer.count), codec, payload])
                bufferStart += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
            let consumed = JSONLScanner.scan(url, from: offset, matching: []) { line in
                guard failure == nil else { return }
                do {
                    // Esvazia ANTES de acrescentar: assim a última linha sempre fica no buffer, e o
                    // ajuste de linha sem `\n` (abaixo) pode corrigi-la.
                    if buffer.count >= Self.chunkSize { try flush() }
                    buffer.append(line)
                    buffer.append(0x0A)
                    position += UInt64(line.count) + 1
                    if Self.mayBeMessage(line), let record = SessionLineParser.parse(line) {
                        try insertMessage.run([fileID, lineNumber, record.uuid, record.type, record.timestamp, record.cwd, record.gitBranch,
                                               record.isSidechain, record.model, record.messageID, record.requestID,
                                               record.inputTokens, record.outputTokens, record.cacheReadTokens, record.cacheCreationTokens,
                                               record.text])
                        if !record.text.isEmpty { try insertFTS.run([db.lastInsertRowID, record.text]) }
                    }
                    lineNumber += 1
                    added += 1
                } catch {
                    failure = error
                }
            }
            if let failure { throw failure }
            guard let consumed else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            if consumed != position, !buffer.isEmpty {
                // A última linha não tinha `\n` (o scanner a consumiu por ser JSON completo, com o
                // espaço em branco final): troca o `\n` presumido pelos bytes reais do arquivo.
                buffer.removeLast()
                position -= 1
                if consumed > position {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: position)
                    buffer.append((try handle.read(upToCount: Int(consumed - position))) ?? Data())
                }
            }
            try flush()
            // Guarda o tamanho/mtime lidos ANTES do scan: se o arquivo cresceu durante a leitura, o
            // próximo ciclo vê `offset != size` e lê o resto.
            try db.prepare("""
            UPDATE files SET head = ?, byte_offset = ?, line_count = ?, size = ?, mtime = ?, last_synced_at = ?, deleted_at = NULL WHERE id = ?
            """).run([head, consumed, lineNumber, size, mtime, now.timeIntervalSince1970, fileID])
            report.linesAdded += added
            if added > 0 || previous == nil { report.filesUpdated += 1 }
        }
    }

    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// Filtro barato antes do `JSONSerialization` (a maioria das linhas são anexos e metadados).
    static func mayBeMessage(_ line: Data) -> Bool {
        line.range(of: userMarker) != nil || line.range(of: assistantMarker) != nil
    }

    /// Tamanho alvo de um bloco antes da compressão.
    static let chunkSize = 1 << 20

    /// Comprime com lzfse quando compensa; blocos pequenos ficam crus.
    static func encode(_ bytes: Data) -> (codec: Int, payload: Data) {
        guard bytes.count >= 128, let compressed = try? (bytes as NSData).compressed(using: .lzfse) as Data,
              compressed.count < bytes.count else { return (0, bytes) }
        return (1, compressed)
    }

    static func decode(codec: Int, payload: Data) throws -> Data {
        guard codec == 1 else { return payload }
        return try (payload as NSData).decompressed(using: .lzfse) as Data
    }

    // MARK: - Search

    public struct SearchHit: Equatable, Sendable {
        public let profileID: String
        public let profileName: String?
        public let resumeID: String
        public let timestamp: String?
        public let cwd: String?
        public let type: String
        public let snippet: String
        public let deleted: Bool
    }

    public func search(_ input: String, limit: Int = 20) throws -> [SearchHit] {
        guard let expression = SessionSearchQuery.ftsExpression(input), FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let db = try open()
        let query = try db.prepare("""
        SELECT f.profile_id, p.name, COALESCE(f.parent_session_id, f.session_id), m.timestamp, m.cwd, m.type,
               snippet(messages_fts, 0, '[', ']', '…', 16), f.deleted_at IS NOT NULL, m.uuid
        FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
        JOIN files f ON f.id = m.file_id LEFT JOIN profiles p ON p.id = f.profile_id
        WHERE messages_fts MATCH ?
        ORDER BY m.timestamp DESC
        LIMIT ?
        """)
        // Revisões antigas repetem as mesmas mensagens: pede folga e deduplica por mensagem.
        try query.bind([expression, limit * 4])
        var hits: [SearchHit] = []
        var seen = Set<String>()
        while try query.step(), hits.count < limit {
            let resume = query.string(2) ?? ""
            let key = "\(query.string(0) ?? ""):\(resume):\(query.string(8) ?? UUID().uuidString)"
            guard seen.insert(key).inserted else { continue }
            hits.append(SearchHit(profileID: query.string(0) ?? "", profileName: query.string(1), resumeID: resume,
                                  timestamp: query.string(3), cwd: query.string(4), type: query.string(5) ?? "",
                                  snippet: (query.string(6) ?? "").replacingOccurrences(of: "\n", with: " "),
                                  deleted: query.int(7) != 0))
        }
        return hits
    }

    // MARK: - Restore

    public enum RestoreError: Error, Equatable, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let id): return "no archived session matches \(id)"
            }
        }
    }

    public struct RestoreResult: Equatable, Sendable {
        public let sessionID: String
        public let profileID: String
        public let cwd: String?
        /// Arquivos recriados no disco.
        public let written: [URL]
        /// Arquivos que já existiam no perfil (o vivo nunca é sobrescrito).
        public let alreadyPresent: [URL]
    }

    public struct SessionCandidate: Equatable, Sendable {
        public let sessionID: String
        public let profileID: String
        public init(sessionID: String, profileID: String) { self.sessionID = sessionID; self.profileID = profileID }
    }

    /// Sessões principais cujo id começa com `sessionPrefix`, em qualquer perfil. Se algum id bate
    /// exatamente, só os exatos voltam (o mesmo id pode existir em dois perfis após uma importação).
    public func candidates(sessionPrefix: String) throws -> [SessionCandidate] {
        guard !sessionPrefix.isEmpty, FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let db = try open()
        let query = try db.prepare("""
        SELECT DISTINCT session_id, profile_id FROM files
        WHERE parent_session_id IS NULL AND session_id LIKE ? ESCAPE '\\' ORDER BY session_id LIMIT 20
        """)
        let escaped = sessionPrefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        try query.bind([escaped + "%"])
        var matches: [SessionCandidate] = []
        while try query.step() { matches.append(SessionCandidate(sessionID: query.string(0) ?? "", profileID: query.string(1) ?? "")) }
        let exact = matches.filter { $0.sessionID == sessionPrefix }
        return exact.isEmpty ? matches : exact
    }

    /// Recria no disco a sessão e as transcrições de subagente dela (revisão mais recente de cada
    /// arquivo), dentro do diretório `destination` do perfil. Arquivos que já existem não são tocados.
    public func restore(sessionID: String, fromProfileID profileID: String, into destination: URL) throws -> RestoreResult {
        let db = try open()
        let files = try db.prepare("""
        SELECT f.id, f.rel_path FROM files f
        WHERE f.profile_id = ? AND (f.session_id = ? AND f.parent_session_id IS NULL OR f.parent_session_id = ?)
          AND f.revision = (SELECT MAX(revision) FROM files g WHERE g.profile_id = f.profile_id AND g.rel_path = f.rel_path)
        """)
        try files.bind([profileID, sessionID, sessionID])
        var targets: [(Int64, String)] = []
        while try files.step() { targets.append((files.int(0), files.string(1) ?? "")) }
        guard !targets.isEmpty else { throw RestoreError.notFound(sessionID) }

        var written: [URL] = []
        var present: [URL] = []
        let chunks = try db.prepare("SELECT codec, data FROM chunks WHERE file_id = ? ORDER BY start_offset")
        for (fileID, relative) in targets {
            let target = destination.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: target.path) { present.append(target); continue }
            var contents = Data()
            try chunks.bind([fileID])
            while try chunks.step() {
                contents.append(try Self.decode(codec: Int(chunks.int(0)), payload: chunks.data(1)))
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, options: [.atomic])
            written.append(target)
        }

        let cwdQuery = try db.prepare("""
        SELECT m.cwd FROM messages m JOIN files f ON f.id = m.file_id
        WHERE f.profile_id = ? AND f.session_id = ? AND f.parent_session_id IS NULL AND m.cwd IS NOT NULL
        ORDER BY f.revision DESC, m.line_no DESC LIMIT 1
        """)
        try cwdQuery.bind([profileID, sessionID])
        let cwd = try cwdQuery.step() ? cwdQuery.string(0) : nil
        return RestoreResult(sessionID: sessionID, profileID: profileID, cwd: cwd, written: written, alreadyPresent: present)
    }
}
