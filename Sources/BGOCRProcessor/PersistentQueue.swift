import Foundation
import os

public actor PersistentQueue {

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "PersistentQueue")

    private let db: DatabaseConnection

    public init(databasePath: String) throws {
        let directory = (databasePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        self.db = try DatabaseConnection(path: databasePath)
        try createSchema()
    }

    public init(connection: DatabaseConnection) throws {
        self.db = connection
        try createSchema()
    }

    private func createSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS queue_items (
                id              TEXT PRIMARY KEY,
                image_path      TEXT NOT NULL,
                batch_id        TEXT NOT NULL,
                status          INTEGER NOT NULL DEFAULT 0,
                result_json     TEXT,
                error_message   TEXT,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL,
                attempt_count   INTEGER NOT NULL DEFAULT 0,
                js_processed    INTEGER NOT NULL DEFAULT 0,
                purge_after     REAL,
                UNIQUE(image_path, batch_id)
            )
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_status ON queue_items(status)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_js_processed ON queue_items(js_processed)")
    }

    public func enqueue(_ paths: [String], batchID: String) throws -> Int {
        let now = Date().timeIntervalSince1970
        var insertedCount = 0

        try db.beginTransaction()
        do {
            for path in paths {
                let id = UUID().uuidString
                let changes = try db.execute(
                    """
                    INSERT OR IGNORE INTO queue_items (id, image_path, batch_id, status, created_at, updated_at, attempt_count, js_processed)
                    VALUES (?, ?, ?, 0, ?, ?, 0, 0)
                    """,
                    params: [id, path, batchID, now, now]
                )
                insertedCount += changes
            }
            try db.commitTransaction()
        } catch {
            try? db.rollbackTransaction()
            throw error
        }

        Self.logger.debug("Enqueued \(insertedCount) of \(paths.count) items for batch \(batchID)")
        return insertedCount
    }

    public func dequeue(limit: Int) throws -> [QueueItem] {
        try db.beginTransaction()
        do {
            let rows = try db.query(
                "SELECT * FROM queue_items WHERE status = ? ORDER BY created_at ASC LIMIT ?",
                params: [QueueItemStatus.pending.rawValue, limit]
            )

            let items = rows.map { rowToQueueItem($0) }
            let now = Date().timeIntervalSince1970

            for item in items {
                try db.execute(
                    "UPDATE queue_items SET status = ?, updated_at = ? WHERE id = ?",
                    params: [QueueItemStatus.processing.rawValue, now, item.id]
                )
            }

            try db.commitTransaction()
            return items
        } catch {
            try? db.rollbackTransaction()
            throw error
        }
    }

    public func markProcessing(_ id: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            "UPDATE queue_items SET status = ?, updated_at = ? WHERE id = ?",
            params: [QueueItemStatus.processing.rawValue, now, id]
        )
    }

    public func markCompleted(_ id: String, resultJSON: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            "UPDATE queue_items SET status = ?, result_json = ?, updated_at = ? WHERE id = ?",
            params: [QueueItemStatus.completed.rawValue, resultJSON, now, id]
        )
    }

    public func markFailed(_ id: String, error: String, attemptCount: Int) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            "UPDATE queue_items SET status = ?, error_message = ?, attempt_count = ?, updated_at = ? WHERE id = ?",
            params: [QueueItemStatus.failed.rawValue, error, attemptCount, now, id]
        )
    }

    public func markPermanentlyFailed(_ id: String, error: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            "UPDATE queue_items SET status = ?, error_message = ?, updated_at = ? WHERE id = ?",
            params: [QueueItemStatus.permanentlyFailed.rawValue, error, now, id]
        )
    }

    public func markJSProcessed(_ ids: [String]) throws {
        let now = Date().timeIntervalSince1970
        let purgeAfter = now + (72 * 60 * 60)

        for id in ids {
            try db.execute(
                "UPDATE queue_items SET js_processed = 1, purge_after = ?, updated_at = ? WHERE id = ?",
                params: [purgeAfter, now, id]
            )
        }
    }

    public func resetStaleProcessing() throws -> Int {
        let now = Date().timeIntervalSince1970

        let staleRows = try db.query(
            "SELECT id, attempt_count FROM queue_items WHERE status = ?",
            params: [QueueItemStatus.processing.rawValue]
        )

        var resetCount = 0

        for row in staleRows {
            guard let id = row["id"] as? String,
                  let attemptCount = row["attempt_count"] as? Int else { continue }

            let newAttemptCount = attemptCount + 1

            if newAttemptCount >= 3 {
                try db.execute(
                    "UPDATE queue_items SET status = ?, error_message = ?, attempt_count = ?, updated_at = ? WHERE id = ?",
                    params: [QueueItemStatus.permanentlyFailed.rawValue, "Max retries exceeded", newAttemptCount, now, id]
                )
            } else {
                try db.execute(
                    "UPDATE queue_items SET status = ?, attempt_count = ?, updated_at = ? WHERE id = ?",
                    params: [QueueItemStatus.pending.rawValue, newAttemptCount, now, id]
                )
            }

            resetCount += 1
        }

        Self.logger.debug("Reset \(resetCount) stale processing items")
        return resetCount
    }

    public func pendingCount() throws -> Int {
        let rows = try db.query(
            "SELECT COUNT(*) as count FROM queue_items WHERE status = ?",
            params: [QueueItemStatus.pending.rawValue]
        )
        return rows.first?["count"] as? Int ?? 0
    }

    public func totalCounts(batchID: String) throws -> (completed: Int, total: Int) {
        let totalRows = try db.query(
            "SELECT COUNT(*) as count FROM queue_items WHERE batch_id = ?",
            params: [batchID]
        )
        let completedRows = try db.query(
            "SELECT COUNT(*) as count FROM queue_items WHERE batch_id = ? AND status = ?",
            params: [batchID, QueueItemStatus.completed.rawValue]
        )

        let total = totalRows.first?["count"] as? Int ?? 0
        let completed = completedRows.first?["count"] as? Int ?? 0
        return (completed: completed, total: total)
    }

    public func unprocessedByJS() throws -> [QueueItem] {
        let rows = try db.query(
            "SELECT * FROM queue_items WHERE status = ? AND js_processed = 0",
            params: [QueueItemStatus.completed.rawValue]
        )
        return rows.map { rowToQueueItem($0) }
    }

    public func autoPurge() throws -> Int {
        let now = Date().timeIntervalSince1970
        let changes = try db.execute(
            "DELETE FROM queue_items WHERE js_processed = 1 AND purge_after IS NOT NULL AND purge_after < ?",
            params: [now]
        )
        if changes > 0 {
            Self.logger.debug("Auto-purged \(changes) items")
        }
        return changes
    }

    public func deleteAll() throws {
        try db.execute("DELETE FROM queue_items")
    }

    public func itemByID(_ id: String) throws -> QueueItem? {
        let rows = try db.query("SELECT * FROM queue_items WHERE id = ?", params: [id])
        return rows.first.map { rowToQueueItem($0) }
    }

    private func rowToQueueItem(_ row: [String: Any]) -> QueueItem {
        QueueItem(
            id: row["id"] as? String ?? "",
            imagePath: row["image_path"] as? String ?? "",
            batchID: row["batch_id"] as? String ?? "",
            status: QueueItemStatus(rawValue: row["status"] as? Int ?? 0) ?? .pending,
            resultJSON: row["result_json"] as? String,
            errorMessage: row["error_message"] as? String,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0),
            attemptCount: row["attempt_count"] as? Int ?? 0,
            jsProcessed: (row["js_processed"] as? Int ?? 0) == 1,
            purgeAfter: (row["purge_after"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
