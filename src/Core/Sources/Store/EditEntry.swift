import Foundation

/// One item of one edit, as the phone applied it.
///
/// The service keeps counts and codes and forgets the rest on purpose, so this
/// is the only place the contents of an edit survive at all. It exists for two
/// reasons: to be read on screen, because an app that changes Health silently
/// is an app nobody should trust with Health; and to be undone, because a
/// record written under an id can be taken back out by that id.
public struct EditEntry: Equatable, Hashable, Sendable, Identifiable {
    /// What became of the item.
    public enum State: String, Sendable, CaseIterable {
        /// A record written into Health, and still there.
        case applied
        /// Health never took it. `code` says why, in a word.
        case refused
        /// A record the agent removed from Health.
        case deleted
        /// A record the agent wrote and the person took back out.
        case undone
        /// A change or a removal the agent asked for and Health has not seen:
        /// it would alter or take away a record that stands there now, and that
        /// is the person's to allow. The item is kept here, whole, because the
        /// service has already been answered and the queue has moved on.
        case waiting
        /// One the person turned down. Health was never touched.
        case declined
    }

    public let id: Int64
    /// The edit this item arrived in, as the service named it.
    public let editName: String
    /// Where in that edit the item sat, which is what an outcome counts by.
    public let item: Int
    /// The agent's own id for the record. Empty for an edit that could not be
    /// opened at all, which has no items to speak of.
    public let recordID: String
    public let state: State
    /// The metric's name on the wire. A deletion names none: the agent gives an
    /// id and nothing else, and the record is gone before anything can ask.
    public let metric: String?
    public let start: Date?
    public let end: Date?
    public let value: Double?
    public let unit: String?
    public let stage: String?
    /// The day in the archive the item landed on, or left.
    public let day: String?
    /// Why it was refused, when it was.
    public let code: OutcomeCode?
    /// When this phone applied it.
    public let at: Date
    public let undoneAt: Date?
    /// What this item pushed out of Health, and what undo puts back. Empty when
    /// it pushed nothing out — an addition — and empty on every row written
    /// before the journal started keeping this.
    public let displaced: [DisplacedRecord]

    public init(
        id: Int64,
        editName: String,
        item: Int,
        recordID: String,
        state: State,
        metric: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        value: Double? = nil,
        unit: String? = nil,
        stage: String? = nil,
        day: String? = nil,
        code: OutcomeCode? = nil,
        at: Date,
        undoneAt: Date? = nil,
        displaced: [DisplacedRecord] = []
    ) {
        self.id = id
        self.editName = editName
        self.item = item
        self.recordID = recordID
        self.state = state
        self.metric = metric
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
        self.stage = stage
        self.day = day
        self.code = code
        self.at = at
        self.undoneAt = undoneAt
        self.displaced = displaced
    }

    /// Whether this one can be taken back.
    ///
    /// An addition is taken back by removing it. A replacement and a removal
    /// are taken back by putting `displaced` where it was. A row from before
    /// the journal kept that — every deletion build 18 wrote — has nothing to
    /// put back and says so rather than offering a button that empties a day.
    public var canBeUndone: Bool {
        guard !recordID.isEmpty else { return false }
        switch state {
        case .applied: return true
        case .deleted: return !displaced.isEmpty
        default: return false
        }
    }

    /// The item this row came from.
    ///
    /// What makes a held item survive a relaunch: the journal carries every
    /// field a `put` has, so nothing of the edit needs to stay in the service's
    /// queue while the person decides. A row with no id is an edit nobody could
    /// open, and there is no item in it to rebuild.
    public var asItem: EditItem? {
        guard !recordID.isEmpty else { return nil }
        guard let metric, let start, let end else { return .delete(id: recordID) }
        return .put(.init(
            id: recordID,
            metric: metric,
            start: Int64(start.timeIntervalSince1970),
            end: Int64(end.timeIntervalSince1970),
            value: value,
            unit: unit,
            stage: stage
        ))
    }
}

/// How many items of each kind, over some stretch of time.
public struct EditTally: Equatable, Sendable {
    public var applied = 0
    public var refused = 0
    public var deleted = 0
    public var undone = 0
    public var waiting = 0
    public var declined = 0

    public init(
        applied: Int = 0,
        refused: Int = 0,
        deleted: Int = 0,
        undone: Int = 0,
        waiting: Int = 0,
        declined: Int = 0
    ) {
        self.applied = applied
        self.refused = refused
        self.deleted = deleted
        self.undone = undone
        self.waiting = waiting
        self.declined = declined
    }

    /// Everything the agent did, undone items included: they were done once.
    /// What is waiting is left out on purpose — it is a question rather than
    /// something that happened, and the screen asks it instead of counting it.
    public var total: Int {
        applied + refused + deleted + undone + declined
    }

    /// Whether the journal has anything at all to show for this stretch.
    public var anything: Bool {
        total + waiting > 0
    }

    /// What is in Health because of the agent right now.
    public var standing: Int {
        applied
    }
}

/// The three answers the screen asks the journal for, in one read.
///
/// How much is waiting has no answer of its own here: it is `ever.waiting`,
/// because no watermark applies to it. A question does not stop being a
/// question by having been looked at.
public struct EditSummary: Equatable, Sendable {
    /// Since the person last opened the list. What the dark strip counts.
    public var unseen = EditTally()
    /// Since the start of today, in the archive's own zone.
    public var today = EditTally()
    /// Everything the journal holds.
    public var ever = EditTally()

    public init(unseen: EditTally = .init(), today: EditTally = .init(), ever: EditTally = .init()) {
        self.unseen = unseen
        self.today = today
        self.ever = ever
    }
}
