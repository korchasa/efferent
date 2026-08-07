import XCTest

@testable import Efferent

final class StoreTests: XCTestCase {
    private func event(_ id: String, _ fields: [String: String]) throws -> Event {
        try Event(id: id, kind: .aggregate, payload: Event.payload(fields))
    }

    func testPendingComesBackInTheOrderItWasRecorded() throws {
        let store = try Store.inMemory()
        try store.commit(events: [
            event("a", ["value": "1"]),
            event("b", ["value": "2"]),
        ])

        let pending = try store.pending(limit: 10)
        XCTAssertEqual(pending.map(\.id), ["a", "b"])
        XCTAssertEqual(pending.map(\.seq), [1, 2])
    }

    /// The daily re-scan re-reads a week of totals every time. Days that did not
    /// move must not turn into traffic.
    func testRecordingAnUnchangedEventCostsNothing() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["value": "1"])])

        let second = try store.commit(events: [event("a", ["value": "1"])])

        XCTAssertEqual(second.enqueued, 0)
        XCTAssertEqual(second.unchanged, 1)
        XCTAssertEqual(try store.pending(limit: 10).count, 1)
    }

    /// A day that grew after the watch synced has to go out again, which means a
    /// fresh sequence number beyond the confirmation mark.
    func testAChangedEventIsQueuedAgainUnderANewSequenceNumber() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["value": "1"])])
        try store.acknowledge(through: 1)
        XCTAssertTrue(try store.pending(limit: 10).isEmpty)

        try store.commit(events: [event("a", ["value": "2"])])

        let pending = try store.pending(limit: 10)
        XCTAssertEqual(pending.map(\.id), ["a"])
        XCTAssertEqual(pending.first?.seq, 2)
    }

    func testAnchorIsReadableAfterTheCommitThatCarriedIt() throws {
        let store = try Store.inMemory()
        let anchor = Anchor(typeIdentifier: "HKQuantityTypeIdentifierStepCount", value: Data([0xAB]))

        try store.commit(events: [event("a", ["value": "1"])], anchor: anchor)

        XCTAssertEqual(try store.anchor(for: "HKQuantityTypeIdentifierStepCount"), Data([0xAB]))
    }

    /// A re-scan that finds nothing new still has to move the anchor forward,
    /// or the reader would hand back the same window again on every wake-up.
    func testTheAnchorMovesEvenWhenNothingChanged() throws {
        let store = try Store.inMemory()
        try store.commit(
            events: [event("a", ["value": "1"])],
            anchor: Anchor(typeIdentifier: "steps", value: Data([0x01]))
        )

        let result = try store.commit(
            events: [event("a", ["value": "1"])],
            anchor: Anchor(typeIdentifier: "steps", value: Data([0x02]))
        )

        XCTAssertEqual(result.enqueued, 0)
        XCTAssertEqual(try store.anchor(for: "steps"), Data([0x02]))
    }

    func testTheConfirmationMarkNeverMovesBackwards() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["v": "1"]), event("b", ["v": "2"])])

        try store.acknowledge(through: 2)
        try store.acknowledge(through: 1)

        XCTAssertEqual(try store.stats().acknowledgedSeq, 2)
    }

    func testConfirmingSomethingNeverSentIsAnError() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["v": "1"])])

        XCTAssertThrowsError(try store.acknowledge(through: 99)) { error in
            XCTAssertEqual(
                error as? StoreError,
                .acknowledgementAheadOfOutbox(acknowledged: 99, nextSeq: 2)
            )
        }
    }

    func testPruningTakesConfirmedRowsAndLeavesTheRest() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["v": "1"]), event("b", ["v": "2"])])
        try store.acknowledge(through: 1)

        let removed = try store.prune(confirmedBefore: Date().addingTimeInterval(60))

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try store.stats().retained, 1)
        XCTAssertEqual(try store.pending(limit: 10).map(\.id), ["b"])
    }

    func testRecentlyConfirmedRowsSurvivePruning() throws {
        let store = try Store.inMemory()
        try store.commit(events: [event("a", ["v": "1"])])
        try store.acknowledge(through: 1)

        let removed = try store.prune(confirmedBefore: Date().addingTimeInterval(-60))

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try store.stats().retained, 1)
    }

    func testBackfillProgressSurvivesAReadBack() throws {
        let store = try Store.inMemory()
        XCTAssertNil(try store.backfillProgress(for: "steps"))

        let reached = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordBackfillProgress(reached, for: "steps")

        let readBack = try XCTUnwrap(store.backfillProgress(for: "steps"))
        XCTAssertEqual(readBack.timeIntervalSince1970, reached.timeIntervalSince1970, accuracy: 0.001)
    }
}
