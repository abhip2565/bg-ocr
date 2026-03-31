import Foundation
import SQLite3
import os

public enum DatabaseError: Error, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case queryFailed(String)
    case transactionFailed(String)
    case connectionClosed
}

public final class DatabaseConnection {

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "DatabaseConnection")

    private var db: OpaquePointer?
    private let path: String
    private let maxBusyRetries = 3
    private let busyRetryDelay: UInt32 = 50_000

    public init(path: String) throws {
        self.path = path
        try open()
    }

    deinit {
        close()
    }

    public func open() throws {
        guard db == nil else { return }
        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK, db != nil else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            db = nil
            throw DatabaseError.openFailed(message)
        }
        try execute("PRAGMA journal_mode=WAL")
    }

    public func close() {
        guard let db = db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    @discardableResult
    public func execute(_ sql: String, params: [Any?] = []) throws -> Int {
        guard let db = db else { throw DatabaseError.connectionClosed }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.executionFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        try bindParams(params, to: statement, db: db)

        var result = sqlite3_step(statement)
        var retryCount = 0

        while result == SQLITE_BUSY && retryCount < maxBusyRetries {
            retryCount += 1
            Self.logger.debug("SQLITE_BUSY, retry \(retryCount)")
            usleep(busyRetryDelay)
            sqlite3_reset(statement)
            result = sqlite3_step(statement)
        }

        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.executionFailed(message)
        }

        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, params: [Any?] = []) throws -> [[String: Any]] {
        guard let db = db else { throw DatabaseError.connectionClosed }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        try bindParams(params, to: statement, db: db)

        var rows: [[String: Any]] = []
        var stepResult = sqlite3_step(statement)
        var busyRetryCount = 0

        while stepResult == SQLITE_BUSY && busyRetryCount < maxBusyRetries {
            busyRetryCount += 1
            Self.logger.debug("SQLITE_BUSY on query, retry \(busyRetryCount)")
            usleep(busyRetryDelay)
            sqlite3_reset(statement)
            stepResult = sqlite3_step(statement)
        }

        while stepResult == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columnCount = sqlite3_column_count(statement)

            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                let type = sqlite3_column_type(statement, i)

                switch type {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_NULL:
                    row[name] = nil as Any?
                default:
                    row[name] = nil as Any?
                }
            }

            rows.append(row)
            stepResult = sqlite3_step(statement)
        }

        return rows
    }

    public func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE")
    }

    public func commitTransaction() throws {
        try execute("COMMIT")
    }

    public func rollbackTransaction() throws {
        try execute("ROLLBACK")
    }

    public func lastInsertRowID() -> Int64 {
        guard let db = db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    private func bindParams(_ params: [Any?], to statement: OpaquePointer?, db: OpaquePointer) throws {
        for (index, param) in params.enumerated() {
            let sqlIndex = Int32(index + 1)
            let result: Int32

            switch param {
            case nil:
                result = sqlite3_bind_null(statement, sqlIndex)
            case let value as String:
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                result = sqlite3_bind_text(statement, sqlIndex, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case let value as Int:
                result = sqlite3_bind_int64(statement, sqlIndex, Int64(value))
            case let value as Int64:
                result = sqlite3_bind_int64(statement, sqlIndex, value)
            case let value as Double:
                result = sqlite3_bind_double(statement, sqlIndex, value)
            case let value as Bool:
                result = sqlite3_bind_int(statement, sqlIndex, value ? 1 : 0)
            default:
                result = sqlite3_bind_null(statement, sqlIndex)
            }

            guard result == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.executionFailed("Bind failed at index \(index): \(message)")
            }
        }
    }
}
