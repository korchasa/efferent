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
    /// Days the service has refused often enough that they are no longer
    /// offered every pass. They are not lost — the daily check against the
    /// archive owes them back — but they are not moving either, and a count
    /// that quietly folded them into the ones still being tried would say
    /// sending was working when it was not.
    public let stuckDays: Int
    /// Days this device has ever put in the archive.
    public let sentDays: Int
    /// When the service last accepted a day. `nil` before it ever has, which is
    /// a different state from "accepted one long ago" and the screen says so
    /// differently.
    public let lastUploadAt: Date?
    /// How far back the first export has walked, if it has started.
    public let backfillReached: String?
}

public enum StoreError: Error, Equatable {
    case archiveChangedWithoutReset(stored: String, current: String)
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

    // MARK: - Archive identity

    /// Attach an existing reader-first destination to its existing ledger.
    ///
    /// Legacy phones do not hold the reading private key, so there is no
    /// evidence that a missing marker means the archive changed. Remember the
    /// current bucket without invalidating claims that already belong to it.
    public func rememberArchive(_ bucket: String) throws {
        try dbQueue.write { db in
            if let stored = try Self.string(db, MetaKey.archiveBucket.rawValue) {
                guard stored == bucket else {
                    throw StoreError.archiveChangedWithoutReset(stored: stored, current: bucket)
                }
                return
            }
            try Self.setString(db, MetaKey.archiveBucket.rawValue, bucket)
        }
    }

    /// Start using a phone-owned archive and invalidate every claim about the
    /// previous one. Returns true exactly once per bucket change.
    ///
    /// Health anchors, sample-to-day rows and the install day describe the
    /// phone, so they survive. Digests, upload time, export progress and the
    /// last reconciliation describe one archive, so they do not. Known days
    /// are queued immediately; the user already made the destructive choice by
    /// disconnecting and creating another archive.
    @discardableResult
    public func activateArchive(_ bucket: String) throws -> Bool {
        try dbQueue.write { db in
            if try Self.string(db, MetaKey.archiveBucket.rawValue) == bucket {
                return false
            }

            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "UPDATE day SET digest = NULL, dirty = 1, updatedAt = ?",
                arguments: [now]
            )
            try db.execute(
                sql: "DELETE FROM meta WHERE key IN (?, ?, ?)",
                arguments: [
                    MetaKey.lastUploadAt.rawValue,
                    MetaKey.backfillReached.rawValue,
                    MetaKey.lastReconciledAt.rawValue,
                ]
            )
            try Self.setString(db, MetaKey.archiveBucket.rawValue, bucket)
            return true
        }
    }

    /// Requeue every known day exactly once when the sealing format changes.
    ///
    /// A plaintext digest cannot prove which envelope version is stored. If it
    /// survived an algorithm change, the ordinary uploader would rebuild an
    /// identical day, call it unchanged and leave the legacy ciphertext in the
    /// archive forever. The version therefore belongs beside the archive's
    /// digests and invalidates them as one transaction.
    @discardableResult
    public func activateSealingVersion(_ version: Int64) throws -> Bool {
        try activate(MetaKey.sealingVersion, version)
    }

    /// Requeue every known day exactly once when the day's layout changes.
    ///
    /// Same reasoning as the sealing version, one level in: a digest is over the
    /// plaintext, so a day repacked in a new layout hashes differently while the
    /// archive still holds the old bytes. Left alone, the ordinary uploader would
    /// rebuild each day, find it unchanged against a claim made about a shape it
    /// no longer writes, and leave the old day up there for good.
    @discardableResult
    public func activateDayFormat(_ version: Int64) throws -> Bool {
        try activate(MetaKey.dayFormat, version)
    }

    private func activate(_ key: MetaKey, _ version: Int64) throws -> Bool {
        try dbQueue.write { db in
            if try Self.int(db, key.rawValue) == version {
                return false
            }

            try db.execute(
                sql: "UPDATE day SET digest = NULL, dirty = 1, updatedAt = ?",
                arguments: [Date().timeIntervalSince1970]
            )
            try Self.setInt(db, key.rawValue, version)
            return true
        }
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
                    ON CONFLICT(day) DO UPDATE SET
                        dirty = 1, updatedAt = excluded.updatedAt, attempts = 0
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
    public func pendingDays(limit: Int, excluding busy: Set<String> = []) throws -> [String] {
        try dbQueue.read { db in
            // Fetched over the limit rather than filtered after it: the days
            // already in the air sit at the head of exactly this order, so a
            // page of the same size would come back made entirely of them and
            // read as "nothing else to send".
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT day FROM day WHERE dirty = 1 AND attempts < ?
                ORDER BY day DESC LIMIT ?
                """,
                arguments: [Self.attemptsBeforeParking, limit + busy.count]
            )
            return busy.isEmpty ? rows : Array(rows.filter { !busy.contains($0) }.prefix(limit))
        }
    }

    /// How many refusals a day is offered through before it is set aside.
    ///
    /// Small on purpose. A day the service will not take does not become
    /// acceptable by being sent a sixth time, and while it is being tried it
    /// stands at the head of the queue in front of days that would go. Nothing
    /// is forgotten: the daily check against the archive owes it back, so a day
    /// set aside is retried once a day rather than never.
    public static let attemptsBeforeParking: Int64 = 5

    /// The service refused these days. Count it against them.
    ///
    /// Returns the days that have now been refused often enough to be set
    /// aside, so the caller can say so once rather than on every pass.
    @discardableResult
    public func recordRefused(_ days: some Collection<String>) throws -> [String] {
        try dbQueue.write { db in
            var parked: [String] = []
            for day in Set(days).sorted() {
                try db.execute(
                    sql: "UPDATE day SET attempts = attempts + 1, updatedAt = ? WHERE day = ?",
                    arguments: [Date().timeIntervalSince1970, day]
                )
                let attempts = try Int64.fetchOne(
                    db, sql: "SELECT attempts FROM day WHERE day = ?", arguments: [day]
                ) ?? 0
                if attempts == Self.attemptsBeforeParking {
                    parked.append(day)
                }
            }
            return parked
        }
    }

    /// How big the sealed object was that the archive accepted for each day.
    ///
    /// Only days that have one: a day sent before this was written down, or one
    /// never sent, has nothing to compare and is left alone rather than
    /// suspected.
    public func sentBytes() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT day, bytes FROM day WHERE bytes IS NOT NULL AND dirty = 0"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["day"] as String, $0["bytes"] as Int) })
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
    public func recordSent(
        day: String,
        digest: Data,
        bytes: Int? = nil,
        sampleIdentifiers: some Collection<UUID>
    ) throws {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                INSERT INTO day (day, digest, dirty, updatedAt, bytes, attempts)
                VALUES (?, ?, 0, ?, ?, 0)
                ON CONFLICT(day) DO UPDATE SET
                    digest = excluded.digest, dirty = 0, updatedAt = excluded.updatedAt,
                    bytes = excluded.bytes, attempts = 0
                """,
                arguments: [day, digest, now, bytes]
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

    /// Mark `days` as owed *and forget what was sent for them*.
    ///
    /// This is the one place a fingerprint is thrown away, and it exists because
    /// a fingerprint is a claim about the archive rather than about Health. It
    /// says "the archive already holds exactly this", and when the archive does
    /// not — a bucket recreated, objects deleted, a move that lost some — the
    /// claim is false and the ordinary path cannot recover from it: the day
    /// would be rebuilt, come out identical, match the fingerprint and never be
    /// sent. Silently, and for history nobody is looking at.
    ///
    /// So `markDirty` keeps the fingerprint and this does not. Both are
    /// idempotent; what differs is the evidence that prompted them.
    @discardableResult
    public func markMissing(_ days: some Collection<String>) throws -> Int {
        try dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            var marked = 0
            for day in Set(days) {
                try db.execute(
                    sql: """
                    INSERT INTO day (day, digest, dirty, updatedAt) VALUES (?, NULL, 1, ?)
                    ON CONFLICT(day) DO UPDATE SET
                        digest = NULL, dirty = 1, updatedAt = excluded.updatedAt, attempts = 0
                    """,
                    arguments: [day, now]
                )
                marked += db.changesCount
            }
            return marked
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

    // MARK: - The clock, and where days are cut

    /// Seconds to add to this device's clock to reach the service's.
    public func clockOffset() throws -> TimeInterval {
        try dbQueue.read { db in
            try TimeInterval(Self.int(db, MetaKey.clockOffset.rawValue) ?? 0)
        }
    }

    public func recordClockOffset(_ seconds: TimeInterval) throws {
        try dbQueue.write { db in
            try Self.setInt(db, MetaKey.clockOffset.rawValue, Int64(seconds.rounded()))
        }
    }

    /// The time zone this archive's days are cut on, pinning it to `current` the
    /// first time anyone asks.
    ///
    /// Asking is what pins it, and it is asked before the first day is ever
    /// built. A phone that has been running for months therefore pins the zone
    /// it has been using all along, and nothing it already sent is re-cut.
    public func dayTimeZone(current: TimeZone = .current) throws -> TimeZone {
        try dbQueue.write { db in
            if let stored = try Self.string(db, MetaKey.dayTimeZone.rawValue),
               let zone = TimeZone(identifier: stored)
            {
                return zone
            }
            try Self.setString(db, MetaKey.dayTimeZone.rawValue, current.identifier)
            return current
        }
    }

    /// The oldest day the first export has reached, if it has started.
    public func backfillReached() throws -> String? {
        try dbQueue.read { db in try Self.string(db, MetaKey.backfillReached.rawValue) }
    }

    public func recordBackfillReached(_ day: String) throws {
        try dbQueue.write { db in try Self.setString(db, MetaKey.backfillReached.rawValue, day) }
    }

    /// When this device last checked the archive against its own ledger, or nil
    /// if it never has — which is why a fresh install checks before it trusts a
    /// ledger it has not yet tested against anything.
    public func lastReconciledAt() throws -> Date? {
        try dbQueue.read { db in
            try Self.int(db, MetaKey.lastReconciledAt.rawValue)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

    public func recordReconciled(at moment: Date = Date()) throws {
        try dbQueue.write { db in
            try Self.setInt(db, MetaKey.lastReconciledAt.rawValue, Int64(moment.timeIntervalSince1970))
        }
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
                    db,
                    sql: "SELECT COUNT(*) FROM day WHERE dirty = 1 AND attempts < ?",
                    arguments: [Self.attemptsBeforeParking]
                ) ?? 0,
                stuckDays: Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM day WHERE dirty = 1 AND attempts >= ?",
                    arguments: [Self.attemptsBeforeParking]
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
