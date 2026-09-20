import Foundation

/// Every item that ever named one record, and which of them speaks for it now.
///
/// The journal is written per item of per edit: that is what an outcome is
/// rebuilt from, and what an edit applied twice has to land on. Health keeps
/// one record per id, and a second `put` under an id replaces the record
/// rather than adding one — which is how an agent corrects itself. So two
/// items can describe one record, and the question the screen actually asks —
/// what is this record now, and what may I do to it — cannot be answered by
/// one item alone. It is answered by this.
///
/// `current` is the item that last touched the id. It alone says what stands
/// in Health and what the person may do about it; the rest are why it says
/// that. Before this type existed the app asked each item separately, and two
/// items over one id offered two keys about one record, one of which could
/// only fail.
public struct RecordHistory: Identifiable, Hashable, Sendable {
    /// What the items were grouped by: the agent's id for the record, or, for
    /// a row that never became a record, something unique to that row.
    public let id: String
    /// Newest first, and never empty.
    public let items: [EditEntry]

    public init(id: String, items: [EditEntry]) {
        precondition(!items.isEmpty, "a record's history is what its items say")
        self.id = id
        self.items = items
    }

    /// The item that last touched the record: what the screen reads, and the
    /// only one the person may act on.
    public var current: EditEntry { items[0] }

    /// The items behind the current one, newest first. Empty for a record
    /// written once and left alone, which is nearly all of them.
    public var earlier: [EditEntry] { Array(items.dropFirst()) }

    /// Whether the person has anything left to do to this record.
    public var personCanAct: Bool { current.personCanAct }
}
