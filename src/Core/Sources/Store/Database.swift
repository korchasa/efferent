import Foundation
import GRDB

/// Schema of the on-device database and the rules it exists to enforce.
///
/// The device deliberately does **not** mirror Health. HealthKit is already the
/// source of truth and sits a millisecond away, so a second full copy would buy
/// nothing and cost hundreds of megabytes plus a migration every time the shape
/// of a record changes. What has to survive a relaunch is only bookkeeping:
///
/// - `day`    — one row per day this device knows about: whether it still has to
///              be sent, and the fingerprint of what was sent last time;
/// - `sample` — which day each HealthKit record belongs to. The one place a
///              record's own contents are shadowed, and only its date;
/// - `anchor` — where each HealthKit reader stopped, one row per sample type;
/// - `meta`   — how far the first export has walked, and when the last day went.
enum Database {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.days") { db in
            // A day is the unit of everything: what gets built, what gets sent,
            // what gets replaced. `digest` is the fingerprint of the body the
            // service last accepted, so rebuilding a day that has not changed
            // costs a comparison instead of an upload.
            try db.create(table: "day") { table in
                table.column("day", .text).primaryKey().notNull()
                table.column("digest", .blob)
                table.column("dirty", .integer).notNull()
                table.column("updatedAt", .double).notNull()
            }
            // Picking the next days to send walks this index instead of the
            // table, which matters once history is four thousand rows long.
            try db.create(index: "day_on_dirty", on: "day", columns: ["dirty", "day"])

            // Deletions are why this exists. HealthKit reports a removed record
            // as a bare identifier — no date, no type — and the record it names
            // is already gone, so nothing can be asked about it afterwards. The
            // day it belonged to is knowable only if it was written down while
            // the record still existed.
            try db.create(table: "sample") { table in
                table.column("uuid", .blob).primaryKey().notNull()
                table.column("day", .text).notNull()
            }
            try db.create(index: "sample_on_day", on: "sample", columns: ["day"])

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

/// Values that live in `meta`. Spelled out here so a typo is a compile error
/// rather than a silently missing value that reads as zero.
enum MetaKey: String {
    /// The bucket whose acceptance claims live in `day.digest`. A digest has no
    /// meaning without this: the same bytes being present in one archive says
    /// nothing about whether another archive holds them.
    case archiveBucket = "archive.bucket"
    /// The oldest day the first export has reached, walking backwards. Absent
    /// until it starts, and left in place when it finishes so a reinstall does
    /// not silently begin again.
    case backfillReached = "backfill.reached"
    /// When a day was last accepted by the service, in seconds since 1970.
    ///
    /// The screen needs one fact above all others — is this still working — and
    /// "nothing waiting" cannot tell "nothing new to send" apart from "stopped a
    /// week ago". A time can.
    case lastUploadAt = "upload.lastAt"
    /// The day this app first ran. Hourly totals begin here: buckets by the hour
    /// for a decade would be several hundred thousand readings at a resolution
    /// nobody asks of last decade.
    case installedDay = "install.day"
    /// When the archive was last compared against what this device believes it
    /// sent, in seconds since 1970. Absent until the first comparison, which is
    /// what makes a device check before it trusts a ledger it has never tested.
    case lastReconciledAt = "reconcile.lastAt"
    /// The sealed-envelope version represented by every non-null day digest.
    /// Changing it invalidates those claims and requeues the known archive.
    case sealingVersion = "sealing.version"
}
