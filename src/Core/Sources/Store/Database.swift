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
/// - `meta`   — how far the first export has walked, and when the last day went;
/// - `written` — the version each agent-given id was last written to Health at;
/// - `editLog` — what an agent changed, kept because nothing else keeps it.
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

        // What the archive said, and what the service said about sending it.
        //
        // `bytes` is the size of the sealed object the archive accepted, so the
        // daily check can compare sizes as well as names: a day that arrived
        // truncated is present, has the right name, and is wrong — the listing
        // is the only place that shows it.
        //
        // `attempts` is how many times the service has refused this day since
        // it was last accepted. A day it will never take — one the frame cannot
        // carry, one it calls malformed — would otherwise be rebuilt on every
        // pass forever, at the head of the queue, in front of the days that
        // would go.
        migrator.registerMigration("v2.evidence") { db in
            try db.alter(table: "day") { table in
                table.add(column: "bytes", .integer)
                table.add(column: "attempts", .integer).notNull().defaults(to: 0)
            }
            try db.drop(index: "day_on_dirty")
            try db.create(
                index: "day_on_dirty", on: "day", columns: ["dirty", "attempts", "day"]
            )
        }

        // What the phone has written into Health at an agent's request.
        //
        // `written` is one row per id an agent has used: the version HealthKit
        // was last handed for it. HealthKit replaces a sample when the same
        // sync identifier arrives with a higher version and ignores a lower or
        // equal one, so the number has to climb across launches and survive
        // the id being deleted — a deleted id that came back at version 1 would
        // be silently ignored for as long as the old version was higher.
        migrator.registerMigration("v3.edits") { db in
            try db.create(table: "written") { table in
                table.column("id", .text).primaryKey().notNull()
                table.column("version", .integer).notNull()
                table.column("updatedAt", .double).notNull()
            }
        }

        // What an agent changed, in the phone's own words.
        //
        // The service is told counts and codes and nothing else, on purpose, so
        // it cannot say what an edit contained — which leaves this the only
        // place the contents survive. Two things read it: the screen, because
        // an app that changes Health silently is an app nobody should trust
        // with Health, and undo, which takes a record back out by its id.
        //
        // Keyed by (editName, item) rather than by the agent's id. An edit is
        // applied again whenever a run dies between writing and answering, and
        // the same id is also how an agent corrects a record it wrote before:
        // both must land on one row, and the second must not stand beside the
        // first.
        migrator.registerMigration("v4.editLog") { db in
            try db.create(table: "editLog") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("editName", .text).notNull()
                table.column("item", .integer).notNull()
                table.column("recordId", .text).notNull()
                table.column("state", .text).notNull()
                table.column("metric", .text)
                table.column("startAt", .double)
                table.column("endAt", .double)
                table.column("value", .double)
                table.column("unit", .text)
                table.column("stage", .text)
                table.column("day", .text)
                table.column("code", .text)
                table.column("appliedAt", .double).notNull()
                table.column("undoneAt", .double)
            }
            try db.create(
                index: "editLog_on_item", on: "editLog", columns: ["editName", "item"], unique: true
            )
            // The screen reads this newest first, and counts a stretch of it.
            try db.create(index: "editLog_on_time", on: "editLog", columns: ["appliedAt"])
        }

        // What a row says and what the service was told can come apart, because
        // a person may approve or turn down a held item while the phone has no
        // network. `owed` is that gap: the decision is already made here, and
        // the service has not heard it yet. The next run pays it.
        migrator.registerMigration("v5.editLog.owed") { db in
            try db.alter(table: "editLog") { table in
                table.add(column: "owed", .boolean).notNull().defaults(to: false)
            }
        }

        // What an item pushed out of Health, so undo can put it back rather
        // than only take the agent's record out. Health hands a displaced
        // record over at the moment of the change and never again.
        //
        // JSON rather than a parallel set of columns: an id is the agent's to
        // choose, nothing stops it naming records under two metrics, and a
        // removal searches every writable metric for it. Null on every row
        // written before this, which is why undo of a deletion asks whether
        // there is anything to put back instead of assuming there is.
        migrator.registerMigration("v6.editLog.displaced") { db in
            try db.alter(table: "editLog") { table in
                table.add(column: "displaced", .text)
            }
        }

        // `owed` went with the question it existed for. It marked a row whose
        // decision the service had not heard yet, and the only thing that made
        // a decision was the screen that asked whether an agent's change could
        // go into Health. Nothing asks now, so nothing is ever owed: an edit's
        // outcome is told once, when it is applied, and never revised.
        migrator.registerMigration("v7.editLog.owed.goes") { db in
            try db.alter(table: "editLog") { table in
                table.drop(column: "owed")
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
    ///
    /// It is also kept out of the device backup, because `editLog` holds the
    /// metric, the value and the instants of everything an agent wrote — health
    /// data, in plain columns, which App Store rule 5.1.3 says may not be put in
    /// iCloud. A backup is exactly that. What that costs is a phone restored
    /// from a backup: it comes back with its keys, because those live in the
    /// Keychain, and with no ledger, so the archive check finds the days
    /// missing and sends them again, and the journal of what an agent changed
    /// starts empty. Both are recoverable; health data in somebody's iCloud is
    /// not.
    static func open(at url: URL) throws -> DatabaseQueue {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        var backup = URLResourceValues()
        backup.isExcludedFromBackup = true
        try directory.setResourceValues(backup)

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
    /// When the recent past was last marked for re-reading, in seconds since
    /// 1970.
    ///
    /// Totals have no anchor, so the only way to notice one moving is to build
    /// those days again and compare — which means reading a week out of Health
    /// in full. A delivery that arrives minutes after the last one cannot find
    /// anything new, because totals are not delivered faster than hourly. This
    /// is what stops the app doing that work twice for nothing.
    case lastRecentMarkAt = "recent.markedAt"
    /// The sealed-envelope version represented by every non-null day digest.
    /// Changing it invalidates those claims and requeues the known archive.
    case sealingVersion = "sealing.version"
    /// The layout every non-null day digest was computed over. It changes when
    /// the way a day packs its events changes, and then every stored day is a
    /// day in the old shape: the digests are claims about bytes nobody writes
    /// any more, and the whole archive is owed again.
    case dayFormat = "day.format"
    /// Seconds to add to this device's clock to get the service's, learned from
    /// the service itself after it refused a signature for being out of time.
    ///
    /// A phone whose clock is wrong cannot notice on its own, and every request
    /// it signs is refused for the same reason forever. The one place the truth
    /// exists is the answer to the refusal, so it is kept.
    case clockOffset = "clock.offset"
    /// The time zone every day boundary in this archive is cut on.
    ///
    /// Pinned once and then left alone. Days are the person's own days, and if
    /// the boundary followed the phone abroad, a week of travel would silently
    /// re-cut a decade of history into different days — every one of them
    /// changed, every one of them owed again.
    case dayTimeZone = "day.timezone"
    /// The bucket whose service holds this phone's editor key. Registering is
    /// a writer-signed request the service answers the same way every time, so
    /// this only saves the round trip; it is cleared with the archive because
    /// another archive is another service-side record.
    case editorRegisteredFor = "editor.bucket"
    /// When the person last opened the list of an agent's edits, in seconds
    /// since 1970.
    ///
    /// The dark strip on the everyday screen counts what has landed since. A
    /// run nobody has looked at is news; the same run tomorrow is history, and
    /// history belongs in the list rather than across the top of the screen.
    case editsSeenAt = "edits.seenAt"
}
