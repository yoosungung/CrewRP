import Foundation
import SQLite3

public struct CacheEntry: Sendable, Equatable {
    public let url: String
    public let body: String
    public let etag: String?
    public let fetchedAt: Date
}

public struct GraphQLCursorRow: Sendable, Equatable {
    public let queryName: String
    public let cursor: String?
    public let updatedAt: Date
}

public final class CacheStore: @unchecked Sendable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw CacheStoreError.openFailed
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS cache_entry (
          url TEXT PRIMARY KEY NOT NULL,
          body TEXT NOT NULL,
          etag TEXT,
          fetched_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS graphql_cursor (
          query_name TEXT PRIMARY KEY NOT NULL,
          cursor TEXT,
          updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          org TEXT NOT NULL,
          repo TEXT NOT NULL,
          team_role TEXT NOT NULL
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    public func putCacheEntry(url: String, body: String, etag: String?, fetchedAt: Date = Date()) throws {
        try exec(
            "INSERT OR REPLACE INTO cache_entry(url, body, etag, fetched_at) VALUES (?, ?, ?, ?);",
            binders: [
                .text(url),
                .text(body),
                etag.map { .text($0) } ?? .null,
                .double(fetchedAt.timeIntervalSince1970),
            ]
        )
    }

    public func cacheEntry(url: String) throws -> CacheEntry? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT url, body, etag, fetched_at FROM cache_entry WHERE url = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw CacheStoreError.prepareFailed
        }
        sqlite3_bind_text(statement, 1, url, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let body = String(cString: sqlite3_column_text(statement, 1))
        let etag: String? = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 2))
        let fetchedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        return CacheEntry(url: url, body: body, etag: etag, fetchedAt: fetchedAt)
    }

    public func putGraphQLCursor(queryName: String, cursor: String?, updatedAt: Date) throws {
        try exec(
            "INSERT OR REPLACE INTO graphql_cursor(query_name, cursor, updated_at) VALUES (?, ?, ?);",
            binders: [
                .text(queryName),
                cursor.map { .text($0) } ?? .null,
                .double(updatedAt.timeIntervalSince1970),
            ]
        )
    }

    public func graphQLCursor(queryName: String) throws -> GraphQLCursorRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT query_name, cursor, updated_at FROM graphql_cursor WHERE query_name = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw CacheStoreError.prepareFailed
        }
        sqlite3_bind_text(statement, 1, queryName, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let cursor: String? = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return GraphQLCursorRow(queryName: queryName, cursor: cursor, updatedAt: updatedAt)
    }

    public func putSession(_ session: Session) throws {
        try exec(
            "INSERT OR REPLACE INTO session(id, org, repo, team_role) VALUES (1, ?, ?, ?);",
            binders: [
                .text(session.org),
                .text(session.repo),
                .text(session.teamRole.rawValue),
            ]
        )
    }

    public func session() throws -> Session? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT org, repo, team_role FROM session WHERE id = 1;", -1, &statement, nil) == SQLITE_OK else {
            throw CacheStoreError.prepareFailed
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let org = String(cString: sqlite3_column_text(statement, 0))
        let repo = String(cString: sqlite3_column_text(statement, 1))
        let roleRaw = String(cString: sqlite3_column_text(statement, 2))
        let role = TeamRole(rawValue: roleRaw) ?? .none
        return Session(org: org, repo: repo, teamRole: role)
    }

    private enum Binder {
        case text(String)
        case double(Double)
        case null
    }

    private func exec(_ sql: String, binders: [Binder] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CacheStoreError.prepareFailed
        }
        for (index, binder) in binders.enumerated() {
            let i = Int32(index + 1)
            switch binder {
            case .text(let value):
                sqlite3_bind_text(statement, i, value, -1, SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(statement, i, value)
            case .null:
                sqlite3_bind_null(statement, i)
            }
        }
        if binders.isEmpty {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                throw CacheStoreError.execFailed
            }
            return
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CacheStoreError.execFailed
        }
    }
}

public enum CacheStoreError: Error {
    case openFailed
    case prepareFailed
    case execFailed
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
