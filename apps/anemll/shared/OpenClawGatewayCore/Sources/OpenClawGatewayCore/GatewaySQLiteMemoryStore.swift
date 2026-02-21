import Foundation
@preconcurrency import SQLite3

public struct GatewayMemoryTurn: Codable, Sendable, Equatable {
    public let id: Int64
    public let sessionKey: String
    public let role: String
    public let text: String
    public let timestampMs: Int64
    public let runID: String?

    public init(
        id: Int64,
        sessionKey: String,
        role: String,
        text: String,
        timestampMs: Int64,
        runID: String? = nil)
    {
        self.id = id
        self.sessionKey = sessionKey
        self.role = role
        self.text = text
        self.timestampMs = timestampMs
        self.runID = runID
    }
}

public struct GatewayMemorySearchHit: Codable, Sendable, Equatable {
    public let turn: GatewayMemoryTurn
    public let score: Double?

    public init(turn: GatewayMemoryTurn, score: Double?) {
        self.turn = turn
        self.score = score
    }
}

public struct GatewayMemorySessionSummary: Codable, Sendable, Equatable {
    public let sessionKey: String
    public let turnCount: Int
    public let lastActivityMs: Int64

    public init(sessionKey: String, turnCount: Int, lastActivityMs: Int64) {
        self.sessionKey = sessionKey
        self.turnCount = turnCount
        self.lastActivityMs = lastActivityMs
    }
}

public struct GatewayMemoryDocument: Codable, Sendable, Equatable {
    public let key: String
    public let sourcePath: String?
    public let content: String
    public let updatedMs: Int64

    public init(key: String, sourcePath: String?, content: String, updatedMs: Int64) {
        self.key = key
        self.sourcePath = sourcePath
        self.content = content
        self.updatedMs = updatedMs
    }
}

public struct GatewayMemoryDocumentSearchHit: Codable, Sendable, Equatable {
    public let document: GatewayMemoryDocument
    public let score: Double?

    public init(document: GatewayMemoryDocument, score: Double?) {
        self.document = document
        self.score = score
    }
}

public enum GatewaySQLiteMemoryStoreError: Error, Sendable, Equatable {
    case openFailed(String)
    case statementFailed(String)
}

public actor GatewaySQLiteMemoryStore {
    private let databasePath: String
    private var database: OpaquePointer?
    private var ftsEnabled = false
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) throws {
        self.databasePath = path.path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let openedDatabase = try Self.openDatabase(path: self.databasePath)
        self.database = openedDatabase
        self.ftsEnabled = try Self.bootstrapSchema(database: openedDatabase)
    }

    public func appendTurn(
        sessionKey: String,
        role: String,
        text: String,
        timestampMs: Int64,
        runID: String?) throws -> GatewayMemoryTurn
    {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let sql = """
            INSERT INTO transcript_turns (session_key, role, text, timestamp_ms, run_id)
            VALUES (?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        let normalizedSession = Self.normalizedSessionKey(sessionKey)
        self.bindText(normalizedSession, at: 1, statement: statement)
        self.bindText(role, at: 2, statement: statement)
        self.bindText(text, at: 3, statement: statement)
        sqlite3_bind_int64(statement, 4, timestampMs)
        self.bindText(runID, at: 5, statement: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }

        let turnID = sqlite3_last_insert_rowid(database)
        let turn = GatewayMemoryTurn(
            id: turnID,
            sessionKey: normalizedSession,
            role: role,
            text: text,
            timestampMs: timestampMs,
            runID: runID)

        if self.ftsEnabled {
            try self.appendToFTS(turn)
        }

        return turn
    }

    public func history(sessionKey: String, limit: Int) throws -> [GatewayMemoryTurn] {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let sql = """
            SELECT id, session_key, role, text, timestamp_ms, run_id
            FROM transcript_turns
            WHERE session_key = ?
            ORDER BY id DESC
            LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText(Self.normalizedSessionKey(sessionKey), at: 1, statement: statement)
        sqlite3_bind_int64(statement, 2, Int64(max(1, min(limit, 1000))))

        var result: [GatewayMemoryTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Self.readTurn(statement))
        }
        return result.reversed()
    }

    public func sessionSummaries(limit: Int = 50) throws -> [GatewayMemorySessionSummary] {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let sql = """
            SELECT session_key, COUNT(*) as turn_count, MAX(timestamp_ms) as last_activity_ms
            FROM transcript_turns
            WHERE session_key != ''
            GROUP BY session_key
            ORDER BY last_activity_ms DESC
            LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(max(1, min(limit, 500))))

        var summaries: [GatewayMemorySessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = Self.readText(statement, at: 0)
            let turnCount = Int(sqlite3_column_int64(statement, 1))
            let lastActivityMs = sqlite3_column_int64(statement, 2)
            summaries.append(
                GatewayMemorySessionSummary(
                    sessionKey: key,
                    turnCount: max(0, turnCount),
                    lastActivityMs: lastActivityMs))
        }
        return summaries
    }

    public func deleteTranscripts(sessionKey: String) throws -> Int {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let normalizedKey = Self.normalizedSessionKey(sessionKey)

        // Delete from FTS mirror first (if enabled).
        if self.ftsEnabled {
            let ftsSql = """
                DELETE FROM transcript_turns_fts WHERE rowid IN (
                    SELECT id FROM transcript_turns WHERE session_key = ?
                )
            """
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(database, ftsSql, -1, &ftsStmt, nil) == SQLITE_OK {
                self.bindText(normalizedKey, at: 1, statement: ftsStmt!)
                sqlite3_step(ftsStmt!)
                sqlite3_finalize(ftsStmt!)
            }
        }

        let sql = "DELETE FROM transcript_turns WHERE session_key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText(normalizedKey, at: 1, statement: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }

        return Int(sqlite3_changes(database))
    }

    public func search(
        query: String,
        sessionKey: String? = nil,
        limit: Int = 10) throws -> [GatewayMemorySearchHit]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = max(1, min(limit, 100))
        if self.ftsEnabled {
            do {
                return try self.searchFTS(
                    query: trimmed,
                    sessionKey: sessionKey,
                    limit: cappedLimit)
            } catch {
                // If FTS syntax rejects a query, fall back to LIKE.
            }
        }
        return try self.searchLike(query: trimmed, sessionKey: sessionKey, limit: cappedLimit)
    }

    public func getTurn(id: Int64) throws -> GatewayMemoryTurn? {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let sql = """
            SELECT id, session_key, role, text, timestamp_ms, run_id
            FROM transcript_turns
            WHERE id = ?
            LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Self.readTurn(statement)
    }

    public func upsertDocument(
        key rawKey: String,
        sourcePath: String?,
        content: String,
        updatedMs: Int64 = GatewayCore.currentTimestampMs()) throws
    {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let sql = """
            INSERT INTO workspace_documents (doc_key, source_path, content, updated_ms)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(doc_key) DO UPDATE SET
                source_path = excluded.source_path,
                content = excluded.content,
                updated_ms = excluded.updated_ms
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText(key, at: 1, statement: statement)
        self.bindText(sourcePath, at: 2, statement: statement)
        self.bindText(content, at: 3, statement: statement)
        sqlite3_bind_int64(statement, 4, updatedMs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
    }

    public func getDocument(key rawKey: String) throws -> GatewayMemoryDocument? {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        let sql = """
            SELECT doc_key, source_path, content, updated_ms
            FROM workspace_documents
            WHERE doc_key = ?
            LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText(key, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Self.readDocument(statement)
    }

    public func searchDocuments(
        query rawQuery: String,
        limit: Int = 10) throws -> [GatewayMemoryDocumentSearchHit]
    {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let cappedLimit = max(1, min(limit, 500))

        let sql = """
            SELECT doc_key, source_path, content, updated_ms
            FROM workspace_documents
            WHERE content LIKE ? OR doc_key LIKE ?
            ORDER BY updated_ms DESC
            LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText("%\(query)%", at: 1, statement: statement)
        self.bindText("%\(query)%", at: 2, statement: statement)
        sqlite3_bind_int64(statement, 3, Int64(cappedLimit))

        let loweredQuery = query.lowercased()
        var results: [GatewayMemoryDocumentSearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let document = Self.readDocument(statement)
            let loweredContent = document.content.lowercased()
            let loweredKey = document.key.lowercased()
            let score = if loweredContent.contains(loweredQuery) {
                1.0
            } else if loweredKey.contains(loweredQuery) {
                0.5
            } else {
                0.1
            }
            results.append(GatewayMemoryDocumentSearchHit(document: document, score: score))
        }
        return results
    }

    private static func openDatabase(path: String) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { Self.lastErrorMessage($0) } ?? "unknown sqlite open error"
            if let database {
                sqlite3_close_v2(database)
            }
            throw GatewaySQLiteMemoryStoreError.openFailed(message)
        }
        guard let database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite open returned nil database")
        }
        return database
    }

    private static func bootstrapSchema(database: OpaquePointer) throws -> Bool {
        try self.execute("""
            CREATE TABLE IF NOT EXISTS transcript_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_key TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                timestamp_ms INTEGER NOT NULL,
                run_id TEXT
            )
        """, database: database)

        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_transcript_turns_session_id ON transcript_turns(session_key, id)",
            database: database)

        try self.execute("""
            CREATE TABLE IF NOT EXISTS workspace_documents (
                doc_key TEXT PRIMARY KEY,
                source_path TEXT,
                content TEXT NOT NULL,
                updated_ms INTEGER NOT NULL
            )
        """, database: database)
        try self.execute(
            "CREATE INDEX IF NOT EXISTS idx_workspace_documents_updated ON workspace_documents(updated_ms DESC)",
            database: database)

        do {
            try self.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS transcript_turns_fts
                USING fts5(text, session_key UNINDEXED, role UNINDEXED, turn_id UNINDEXED)
            """, database: database)
            return true
        } catch {
            return false
        }
    }

    private func appendToFTS(_ turn: GatewayMemoryTurn) throws {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }
        let sql = """
            INSERT INTO transcript_turns_fts (text, session_key, role, turn_id)
            VALUES (?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        self.bindText(turn.text, at: 1, statement: statement)
        self.bindText(turn.sessionKey, at: 2, statement: statement)
        self.bindText(turn.role, at: 3, statement: statement)
        sqlite3_bind_int64(statement, 4, turn.id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
    }

    private func searchFTS(
        query: String,
        sessionKey: String?,
        limit: Int) throws -> [GatewayMemorySearchHit]
    {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let hasSessionFilter = !(sessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sql = if hasSessionFilter {
            """
                SELECT t.id, t.session_key, t.role, t.text, t.timestamp_ms, t.run_id, bm25(transcript_turns_fts)
                FROM transcript_turns_fts
                JOIN transcript_turns t ON t.id = transcript_turns_fts.turn_id
                WHERE transcript_turns_fts MATCH ? AND transcript_turns_fts.session_key = ?
                ORDER BY bm25(transcript_turns_fts), t.id DESC
                LIMIT ?
            """
        } else {
            """
                SELECT t.id, t.session_key, t.role, t.text, t.timestamp_ms, t.run_id, bm25(transcript_turns_fts)
                FROM transcript_turns_fts
                JOIN transcript_turns t ON t.id = transcript_turns_fts.turn_id
                WHERE transcript_turns_fts MATCH ?
                ORDER BY bm25(transcript_turns_fts), t.id DESC
                LIMIT ?
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        self.bindText(query, at: bindIndex, statement: statement)
        bindIndex += 1
        if hasSessionFilter {
            self.bindText(Self.normalizedSessionKey(sessionKey), at: bindIndex, statement: statement)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, Int64(limit))

        var result: [GatewayMemorySearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let turn = Self.readTurn(statement)
            let score = sqlite3_column_double(statement, 6)
            result.append(GatewayMemorySearchHit(turn: turn, score: score))
        }
        return result
    }

    private func searchLike(
        query: String,
        sessionKey: String?,
        limit: Int) throws -> [GatewayMemorySearchHit]
    {
        guard let database = self.database else {
            throw GatewaySQLiteMemoryStoreError.openFailed("sqlite database not open")
        }

        let hasSessionFilter = !(sessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sql = if hasSessionFilter {
            """
                SELECT id, session_key, role, text, timestamp_ms, run_id
                FROM transcript_turns
                WHERE text LIKE ? AND session_key = ?
                ORDER BY id DESC
                LIMIT ?
            """
        } else {
            """
                SELECT id, session_key, role, text, timestamp_ms, run_id
                FROM transcript_turns
                WHERE text LIKE ?
                ORDER BY id DESC
                LIMIT ?
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GatewaySQLiteMemoryStoreError.statementFailed(Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        self.bindText("%\(query)%", at: bindIndex, statement: statement)
        bindIndex += 1
        if hasSessionFilter {
            self.bindText(Self.normalizedSessionKey(sessionKey), at: bindIndex, statement: statement)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, Int64(limit))

        var result: [GatewayMemorySearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let turn = Self.readTurn(statement)
            result.append(GatewayMemorySearchHit(turn: turn, score: nil))
        }
        return result
    }

    private func bindText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? Self.lastErrorMessage(database)
            sqlite3_free(errorPointer)
            throw GatewaySQLiteMemoryStoreError.statementFailed(message)
        }
    }

    private static func lastErrorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func readTurn(_ statement: OpaquePointer?) -> GatewayMemoryTurn {
        GatewayMemoryTurn(
            id: sqlite3_column_int64(statement, 0),
            sessionKey: self.readText(statement, at: 1),
            role: self.readText(statement, at: 2),
            text: self.readText(statement, at: 3),
            timestampMs: sqlite3_column_int64(statement, 4),
            runID: self.readOptionalText(statement, at: 5))
    }

    private static func readDocument(_ statement: OpaquePointer?) -> GatewayMemoryDocument {
        GatewayMemoryDocument(
            key: self.readText(statement, at: 0),
            sourcePath: self.readOptionalText(statement, at: 1),
            content: self.readText(statement, at: 2),
            updatedMs: sqlite3_column_int64(statement, 3))
    }

    private static func readText(_ statement: OpaquePointer?, at index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func readOptionalText(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return self.readText(statement, at: index)
    }

    private static func normalizedSessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }
}
