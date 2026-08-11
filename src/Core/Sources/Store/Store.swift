import Foundation
import GRDB

/// Where a HealthKit reader stopped, as HealthKit itself describes it.
///
/// The value is an archived `HKQueryAnchor`; this layer never looks inside it.
public struct Anchor: Equatable, Sendable {
    public let typeIdentifier: String
    public let value: Data

    public init(typeIdentifier: String, value: Data) {
        self.typeIdentifier = typeIdentifier
        self.value = value
    }
}

public struct Stats: Equatable, Sendable {
    /// Days waiting to be built and sent.
    public let pendingDays: Int
    /// Days this device has ever put in the archive.
    public let sentDays: Int
    /// When the service last accepted a day. `nil` before it ever has, which is
    /// a different state from "accepted one long ago" and the screen says so
    /// differently.
    public let lastUploadAt: Date?
    /// How far back the first export has walked, if it has started.
    public let backfillReached: String?
}

/// The device's durable state: which days still have to go, and where each
/// reader stopped.
public final class Store {
    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        dbQueue = try Database.open(at: url)
    }

    /// A database that lives only as long as this object. For tests.
    public static func inMemory() throws -> Store {
        try Store(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Database.migrator().migrate(dbQueue)
    }

    // MARK: - Noticing what changed

    /// Mark `days` as needing to be built and sent, and move `anchor` forward.
    ///
    /// One transaction, and that is the whole point. The anchor is HealthKit's
    /// "you have seen everything up to here"; saved on its own, with the app
    /// dying before the marks landed, the days it stands for would never be
    /// offered again. Data loss with no error anywhere.
    ///
    /// A day already waiting stays waiting — marking is idempotent, which is
    /// what lets every path that notices a change call this without checking
    /// whether some other path noticed first.
    @discardableResult
    public func markDirty(_ days: some Collection<String>, anchor: Anchor? = nil) throws -> Int {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            var marked = 0
            for day in Set(days) {
                try db.execute(
                    sql: """
                    INSERT INTO day (day, digest, dirty, updatedAt) VALUES (?, NULL, 1, ?)
                    ON CONFLICT(day) DO UPDATE SET dirty = 1, updatedAt = excluded.updatedAt
                    WHERE day.dirty = 0
                    """,
                    arguments: [day, now]
                )
                marked += db.changesCount
            }

            if let anchor {
                try db.execute(
                    sql: """
                    INSERT INTO anchor (typeIdentifier, value, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(typeIdentifier) DO UPDATE SET
                        value = excluded.value, updatedAt = excluded.updatedAt
                    """,
                    arguments: [anchor.typeIdentifier, anchor.value, now]
                )
            }
            return marked
        }
    }

    /// Which days a set of removed records belonged to.
    ///
    /// HealthKit hands over an identifier and nothing else when something is
    /// deleted, and the record it names is already gone from the store — so this
    /// table is the only way left to know which day has to be rebuilt without it.
    public func days(ofRemoved identifiers: some Collection<UUID>) throws -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        return try dbQueue.read { db in
            var days: Set<String> = []
            // In chunks: SQLite has a ceiling on how many values one statement
            // may bind, and a person who cleared a year of workouts at once
            // would otherwise crash the app that was trying to keep up.
            for chunk in Array(identifiers).chunked(into: 500) {
                let blobs: [any DatabaseValueConvertible] = chunk.map(Self.blob)
                let placeholders = Array(repeating: "?", count: blobs.count).joined(separator: ",")
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT day FROM sample WHERE uuid IN (\(placeholders))",
                    arguments: StatementArguments(blobs)
                )
                days.formUnion(rows)
            }
            return days
        }
    }

    // MARK: - Sending

    /// The days waiting to go, most recent first.
    ///
    /// Recent first because today is what anyone reading this actually wants,
    /// and the first export walks backwards anyway — so newest-first keeps the
    /// two in the same order instead of making the fresh data queue behind a
    /// decade of history.
    public func pendingDays(limit: Int) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT day FROM day WHERE dirty = 1 ORDER BY day DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    /// The fingerprint of the body the service last accepted for `day`.
    public func digest(for day: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT digest FROM day WHERE day = ?", arguments: [day])
        }
    }

    /// Record that `day` is now in the archive with these contents.
    ///
    /// The records that made it up are written down at the same moment, because
    /// they are what a later deletion will be looked up in. Old rows for the day
    /// go first: a record that moved to another day, or was removed, must not
    /// leave a row behind pointing at a day it is no longer in.
    public func recordSent(day: String, digest: Data, sampleIdentifiers: some Collection<UUID>) throws {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                INSERT INTO day (day, digest, dirty, updatedAt) VALUES (?, ?, 0, ?)
                ON CONFLICT(day) DO UPDATE SET
                    digest = excluded.digest, dirty = 0, updatedAt = excluded.updatedAt
                """,
                arguments: [day, digest, now]
            )

            try db.execute(sql: "DELETE FROM sample WHERE day = ?", arguments: [day])
            for identifier in sampleIdentifiers {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sample (uuid, day) VALUES (?, ?)",
                    arguments: [Self.blob(identifier), day]
                )
            }

            try Self.setInt(db, MetaKey.lastUploadAt.rawValue, Int64(now))
        }
    }

    /// A day was rebuilt and came out exactly as it was sent. Nothing to upload,
    /// and nothing owed.
    public func markClean(day: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE day SET dirty = 0, updatedAt = ? WHERE day = ?",
                arguments: [Date().timeIntervalSince1970, day]
            )
        }
    }

    // MARK: - Reader state

    public func anchor(for typeIdentifier: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(
                db, sql: "SELECT value FROM anchor WHERE typeIdentifier = ?",
                arguments: [typeIdentifier]
            )
        }
    }

    /// The oldest day the first export has reached, if it has started.
    public func backfillReached() throws -> String? {
        try dbQueue.read { db in try Self.string(db, MetaKey.backfillReached.rawValue) }
    }

    public func recordBackfillReached(_ day: String) throws {
        try dbQueue.write { db in try Self.setString(db, MetaKey.backfillReached.rawValue, day) }
    }

    /// The day this app first ran, remembered the first time it is asked for.
    /// Hourly totals begin here and history before it is daily only.
    public func installedDay(defaultingTo today: String) throws -> String {
        try dbQueue.write { db in
            if let stored = try Self.string(db, MetaKey.installedDay.rawValue) {
                return stored
            }
            try Self.setString(db, MetaKey.installedDay.rawValue, today)
            return today
        }
    }

    public func stats() throws -> Stats {
        try dbQueue.read { db in
            try Stats(
                pendingDays: Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM day WHERE dirty = 1"
                ) ?? 0,
                sentDays: Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM day WHERE digest IS NOT NULL"
                ) ?? 0,
                lastUploadAt: Self.int(db, MetaKey.lastUploadAt.rawValue)
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) },
                backfillReached: Self.string(db, MetaKey.backfillReached.rawValue)
            )
        }
    }

    // MARK: - meta helpers

    /// The sixteen bytes of a UUID. Stored as bytes rather than as the
    /// thirty-six character text: this table has a row per record in Health, so
    /// the difference is megabytes on a phone that has been running for years.
    private static func blob(_ identifier: UUID) -> Data {
        withUnsafeBytes(of: identifier.uuid) { Data($0) }
    }

    private static func int(_ db: GRDB.Database, _ key: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    private static func setInt(_ db: GRDB.Database, _ key: String, _ value: Int64) throws {
        try db.execute(
            sql: """
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    private static func string(_ db: GRDB.Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    private static func setString(_ db: GRDB.Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
