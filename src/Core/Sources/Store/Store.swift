import Foundation
import GRDB

/// An event that has been recorded but not yet confirmed by the server.
public struct PendingEvent: Equatable, Sendable {
    public let id: String
    public let seq: Int64
    public let kind: Event.Kind
    public let payload: Data
}

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

public struct CommitResult: Equatable, Sendable {
    /// Events that were new or had changed, and therefore got a sequence number.
    public let enqueued: Int
    /// Events already in the outbox with byte-identical contents. Re-reading a
    /// week of daily totals normally lands here, and costs nothing.
    public let unchanged: Int
    public let highestSeq: Int64?
}

public struct Stats: Equatable, Sendable {
    public let pending: Int
    public let retained: Int
    public let acknowledgedSeq: Int64
    public let nextSeq: Int64
}

public enum StoreError: Error, Equatable {
    /// The server confirmed a sequence number this device never issued.
    case acknowledgementAheadOfOutbox(acknowledged: Int64, nextSeq: Int64)
    /// A stored row names a kind this build does not know — a downgrade, or a
    /// database written by a newer version of the app.
    case unknownEventKind(id: String, kind: String)
}

/// The device's durable state: what still has to be sent, and where each reader
/// stopped.
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

    // MARK: - Recording

    /// Record `events` and move `anchor` forward, both or neither.
    ///
    /// One transaction, and that is the whole point. The anchor is HealthKit's
    /// "you have seen everything up to here"; if it were saved separately and
    /// the app died in between, the events it stands for would be lost and
    /// HealthKit would never offer them again. Data loss with no error anywhere.
    ///
    /// An event whose payload is byte-for-byte what is already stored is left
    /// alone. That is what keeps the daily re-scan cheap: recomputing the last
    /// seven days of totals enqueues only the days that actually moved.
    @discardableResult
    public func commit(events: [Event], anchor: Anchor? = nil) throws -> CommitResult {
        try dbQueue.write { db in
            var nextSeq = try Self.int(db, MetaKey.nextSeq.rawValue) ?? 1
            var enqueued = 0
            var unchanged = 0
            var highestSeq: Int64?
            let now = Date().timeIntervalSince1970

            for event in events {
                let stored = try Data.fetchOne(
                    db, sql: "SELECT payload FROM outbox WHERE id = ?", arguments: [event.id]
                )
                if stored == event.payload {
                    unchanged += 1
                    continue
                }

                try db.execute(
                    sql: """
                    INSERT INTO outbox (id, seq, kind, payload, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        seq = excluded.seq,
                        kind = excluded.kind,
                        payload = excluded.payload,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [event.id, nextSeq, event.kind.rawValue, event.payload, now]
                )
                highestSeq = nextSeq
                nextSeq += 1
                enqueued += 1
            }

            try Self.setInt(db, MetaKey.nextSeq.rawValue, nextSeq)

            if let anchor {
                try db.execute(
                    sql: """
                    INSERT INTO anchor (typeIdentifier, value, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(typeIdentifier) DO UPDATE SET
                        value = excluded.value,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [anchor.typeIdentifier, anchor.value, now]
                )
            }

            return CommitResult(enqueued: enqueued, unchanged: unchanged, highestSeq: highestSeq)
        }
    }

    // MARK: - Sending

    /// The oldest unconfirmed events, in order.
    public func pending(limit: Int) throws -> [PendingEvent] {
        try dbQueue.read { db in
            let acknowledged = try Self.int(db, MetaKey.acknowledgedSeq.rawValue) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, seq, kind, payload FROM outbox
                WHERE seq > ? ORDER BY seq LIMIT ?
                """,
                arguments: [acknowledged, limit]
            )
            return try rows.map { row in
                let raw: String = row["kind"]
                guard let kind = Event.Kind(rawValue: raw) else {
                    throw StoreError.unknownEventKind(id: row["id"], kind: raw)
                }
                return PendingEvent(id: row["id"], seq: row["seq"], kind: kind, payload: row["payload"])
            }
        }
    }

    /// Move the confirmation mark forward to `seq`.
    ///
    /// Only ever forward: a background upload that finishes out of order must
    /// not walk the mark back and cause everything after it to be sent again.
    public func acknowledge(through seq: Int64) throws {
        try dbQueue.write { db in
            let nextSeq = try Self.int(db, MetaKey.nextSeq.rawValue) ?? 1
            guard seq < nextSeq else {
                throw StoreError.acknowledgementAheadOfOutbox(acknowledged: seq, nextSeq: nextSeq)
            }
            let current = try Self.int(db, MetaKey.acknowledgedSeq.rawValue) ?? 0
            try Self.setInt(db, MetaKey.acknowledgedSeq.rawValue, max(current, seq))
        }
    }

    /// Drop confirmed events last touched before `cutoff`, returning how many went.
    ///
    /// Confirmed rows are not deleted straight away on purpose: they are what
    /// ``commit(events:anchor:)`` compares against to notice that a recomputed
    /// day is unchanged. Keep them for longer than the re-scan window — a month
    /// against a week — and the comparison always has something to compare to.
    @discardableResult
    public func prune(confirmedBefore cutoff: Date) throws -> Int {
        try dbQueue.write { db in
            let acknowledged = try Self.int(db, MetaKey.acknowledgedSeq.rawValue) ?? 0
            try db.execute(
                sql: "DELETE FROM outbox WHERE seq <= ? AND updatedAt < ?",
                arguments: [acknowledged, cutoff.timeIntervalSince1970]
            )
            return db.changesCount
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

    /// How far back the first full export has reached for `metric`, if started.
    public func backfillProgress(for metric: String) throws -> Date? {
        try dbQueue.read { db in
            try Double.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [MetaKey.backfillProgress(metric: metric)]
            ).map(Date.init(timeIntervalSince1970:))
        }
    }

    public func recordBackfillProgress(_ date: Date, for metric: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [MetaKey.backfillProgress(metric: metric), date.timeIntervalSince1970]
            )
        }
    }

    public func stats() throws -> Stats {
        try dbQueue.read { db in
            let acknowledged = try Self.int(db, MetaKey.acknowledgedSeq.rawValue) ?? 0
            let nextSeq = try Self.int(db, MetaKey.nextSeq.rawValue) ?? 1
            let pending = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM outbox WHERE seq > ?", arguments: [acknowledged]
            ) ?? 0
            let retained = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") ?? 0
            return Stats(
                pending: pending, retained: retained,
                acknowledgedSeq: acknowledged, nextSeq: nextSeq
            )
        }
    }

    // MARK: - meta helpers

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
}
