import Foundation

/// One item of one edit, as the phone applied it.
///
/// The service keeps counts and codes and forgets the rest on purpose, so this
/// is the only place the contents of an edit survive at all. It exists for two
/// reasons: to be read on screen, because an app that changes Health silently
/// is an app nobody should trust with Health; and to be changed by the person,
/// because a record written under an id can be reached again by that id.
public struct EditEntry: Equatable, Hashable, Sendable, Identifiable {
    /// What the record is now.
    ///
    /// This app has two operations against Health and no more — writing a
    /// record and removing one — and this says which of them the row ended on.
    /// It deliberately says nothing about who asked: that is `askedBy`, and
    /// keeping the two apart is the whole point. A row where the person took
    /// out what the agent wrote is `removed` by the person, in exactly the same
    /// words as a removal the agent asked for, because it is the same thing
    /// happening to Health.
    public enum State: String, Sendable, CaseIterable {
        /// A record stands in Health because of this row.
        case written
        /// The record is out of Health.
        case removed
        /// Health never took it. `code` says why, in a word.
        case refused
        /// A change or a removal the agent asked for and Health has not seen:
        /// it would alter or take away a record that stands there now, and that
        /// is the person's to allow. The item is kept here, whole, because the
        /// service has already been answered and the queue has moved on.
        case waiting
        /// One the person turned down. Health was never touched.
        case declined
    }

    /// Who asked for what the row now says.
    ///
    /// A row begins as the agent's and becomes the person's the moment they
    /// change it — there is no third party and no third state. Nothing here
    /// reaches the service or the archive: who acted is as private as what the
    /// record held.
    public enum Asker: String, Sendable, CaseIterable {
        case agent
        case person
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
    /// Who the state above is the doing of.
    public let askedBy: Asker
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
    /// When this phone applied what the agent asked for.
    public let at: Date
    /// When the person changed it, and nothing when they never have.
    public let personActedAt: Date?
    /// What this item pushed out of Health, and what a write back puts there
    /// again. Empty when it pushed nothing out — an addition — and empty on
    /// every row written before the journal started keeping this.
    public let displaced: [DisplacedRecord]

    public init(
        id: Int64,
        editName: String,
        item: Int,
        recordID: String,
        state: State,
        askedBy: Asker = .agent,
        metric: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        value: Double? = nil,
        unit: String? = nil,
        stage: String? = nil,
        day: String? = nil,
        code: OutcomeCode? = nil,
        at: Date,
        personActedAt: Date? = nil,
        displaced: [DisplacedRecord] = []
    ) {
        self.id = id
        self.editName = editName
        self.item = item
        self.recordID = recordID
        self.state = state
        self.askedBy = askedBy
        self.metric = metric
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
        self.stage = stage
        self.day = day
        self.code = code
        self.at = at
        self.personActedAt = personActedAt
        self.displaced = displaced
    }

    /// Whether there is anything left for the person to do to this row.
    ///
    /// A record the agent wrote is taken out by removing it; a record the agent
    /// removed is brought back by writing what it displaced. A row from before
    /// the journal kept that — every removal build 18 wrote — has nothing to
    /// write back and says so rather than offering a key that empties a day.
    ///
    /// Only the agent's rows qualify: once the person has acted, the row says
    /// what they left and there is no acting on it twice.
    public var personCanAct: Bool {
        guard !recordID.isEmpty, askedBy == .agent else { return false }
        switch state {
        case .written: return true
        case .removed: return !displaced.isEmpty
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
///
/// Counted by the pair the journal now keeps — what happened to the record, and
/// who asked — because the screens ask both questions and neither answers the
/// other. The strip across the everyday screen reports a run the agent made and
/// nobody has looked at; the legend above the keys reports everything, the
/// person's own corrections included.
public struct EditTally: Equatable, Sendable {
    /// Records the agent wrote that stand as the agent left them.
    public var written = 0
    /// Records the agent removed and the person has not brought back.
    public var removed = 0
    public var refused = 0
    public var waiting = 0
    public var declined = 0
    /// Rows the person wrote back after the agent had removed or replaced them.
    public var personWrote = 0
    /// Rows the person took out of Health after the agent had written them.
    public var personRemoved = 0

    public init(
        written: Int = 0,
        removed: Int = 0,
        refused: Int = 0,
        waiting: Int = 0,
        declined: Int = 0,
        personWrote: Int = 0,
        personRemoved: Int = 0
    ) {
        self.written = written
        self.removed = removed
        self.refused = refused
        self.waiting = waiting
        self.declined = declined
        self.personWrote = personWrote
        self.personRemoved = personRemoved
    }

    /// Everything the agent ever did here, the rows the person has since
    /// changed included: those happened once. What is waiting is left out on
    /// purpose — it is a question rather than something that happened, and the
    /// screen asks it instead of counting it.
    public var total: Int {
        written + removed + refused + declined + personWrote + personRemoved
    }

    /// What the person has since changed, whichever way round.
    public var byPerson: Int {
        personWrote + personRemoved
    }

    /// Whether the journal has anything at all to show for this stretch.
    public var anything: Bool {
        total + waiting > 0
    }

    /// What is in Health because of the agent right now. A row the person took
    /// out is not standing, and one they wrote back stands because of them.
    public var standing: Int {
        written
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
