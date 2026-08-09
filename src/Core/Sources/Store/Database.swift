import Foundation
import GRDB

/// Schema of the on-device database and the rules it exists to enforce.
///
/// The device deliberately does **not** mirror Health. HealthKit is already the
/// source of truth and sits a millisecond away, so a second full copy would buy
/// nothing and cost hundreds of megabytes plus a migration every time the shape
/// of a record changes. Three small things do have to survive a relaunch, and
/// this is all of them:
///
/// - `outbox` — facts waiting to reach the server, in the order they were made;
/// - `anchor` — where each HealthKit reader stopped, one row per sample type;
/// - `meta`   — the counters: next sequence number, last sequence the server
///              confirmed, and how far the first full export has got.
enum Database {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.initial") { db in
            // Keyed by the event's own stable id, so re-reading the same slice
            // of Health lands on the same row instead of appending a duplicate.
            try db.create(table: "outbox") { table in
                table.column("id", .text).primaryKey().notNull()
                table.column("seq", .integer).notNull()
                table.column("kind", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .double).notNull()
            }
            // Sending walks this index in order and never scans the table.
            try db.create(index: "outbox_on_seq", on: "outbox", columns: ["seq"], unique: true)

            try db.create(table: "anchor") { table in
                table.column("typeIdentifier", .text).primaryKey().notNull()
                table.column("value", .blob).notNull()
                table.column("updatedAt", .double).notNull()
            }

            try db.create(table: "meta") { table in
                table.column("key", .text).primaryKey().notNull()
                table.column("value", .blob).notNull()
            }
        }

        return migrator
    }

    /// Open (creating if needed) the database at `url` and bring it up to date.
    ///
    /// The containing directory is marked
    /// `completeUntilFirstUserAuthentication`. Without it a write from a
    /// background HealthKit delivery would fail whenever the phone happens to be
    /// locked — which is most of the time this app runs.
    static func open(at url: URL) throws -> DatabaseQueue {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )

        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        return queue
    }
}

/// Counters that live in `meta`. Spelled out here so a typo is a compile error
/// rather than a silently missing value that reads as zero.
enum MetaKey: String {
    /// Sequence number the next enqueued event will take. Starts at 1.
    case nextSeq = "outbox.nextSeq"
    /// Highest sequence number the server has confirmed. Starts at 0.
    case acknowledgedSeq = "outbox.acknowledgedSeq"

    /// How far back the first full export has walked for one metric.
    static func backfillProgress(metric: String) -> String {
        "backfill.\(metric)"
    }
}
