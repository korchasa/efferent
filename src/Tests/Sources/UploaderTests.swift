import CryptoKit
@testable import Efferent
import XCTest

/// The pass guard and the fingerprint check — the two places where a day either
/// stops going out or goes out for nothing.
///
/// A pass builds the days that are waiting and hands the changed ones to the
/// system; the next pass starts from the completion of the last one. That only
/// works if every path out of `send` releases the claim. An early return that
/// keeps it held stops the app for good, and it stops it looking healthy.
final class UploaderTests: XCTestCase {
    private func makeUploader(
        store: Store,
        identifier: String,
        build: @escaping ([String]) async throws -> [String: DayContents] = { _ in [:] }
    ) throws -> Uploader {
        try Uploader(
            // A session identifier per test: background sessions are global to
            // the process, and two tests sharing one would share its tasks.
            configuration: .init(sessionIdentifier: identifier),
            destination: Destination(
                endpoint: URL(string: "https://example.invalid")!,
                readingPublicKey: WireTests.readingPublicKey
            ),
            store: store,
            identity: DeviceIdentity(),
            build: build
        )
    }

    func testNoDaysWaitingDoesNotHoldTheClaim() async throws {
        let store = try Store.inMemory()
        let uploader = try makeUploader(store: store, identifier: "test.empty.\(UUID().uuidString)")

        // Nothing to send is the commonest outcome by far — it happens on every
        // wake-up that brought no new readings. Holding the claim there would
        // silence the app after its first idle minute.
        let first = try await uploader.send()
        let second = try await uploader.send()

        XCTAssertEqual(first, .nothingToSend)
        XCTAssertEqual(second, .nothingToSend, "the claim outlived a send that had nothing to do")
    }

    /// Re-reading the last week happens on every refresh. A day that came back
    /// exactly as it was sent must cost a comparison and no network at all —
    /// otherwise the phone re-uploads a week of unchanged history every hour.
    func testARebuiltDayThatDidNotChangeIsNotSentAgain() async throws {
        let store = try Store.inMemory()
        let events = [try Event(id: "a", payload: Event.payload(["v": "1"]))]
        let digest = Data(SHA256.hash(data: try NDJSON.body(events)))
        try store.recordSent(day: "2026-08-07", digest: digest, sampleIdentifiers: [])
        try store.markDirty(["2026-08-07"])

        let uploader = try makeUploader(store: store, identifier: "test.same.\(UUID().uuidString)") { _ in
            ["2026-08-07": DayContents(events: events, sampleIdentifiers: [])]
        }
        let outcome = try await uploader.send()

        XCTAssertEqual(outcome, .scheduled(days: 0, unchanged: 1))
        XCTAssertTrue(try store.pendingDays(limit: 10).isEmpty, "an unchanged day stayed waiting")
    }

    /// A day Health has nothing for is still a fact about that day. Without an
    /// entry it would stay marked forever and be rebuilt on every single pass.
    func testADayHealthKnowsNothingAboutStopsWaiting() async throws {
        let store = try Store.inMemory()
        try store.markDirty(["2026-08-07"])
        let uploader = try makeUploader(store: store, identifier: "test.empty-day.\(UUID().uuidString)") { days in
            Dictionary(uniqueKeysWithValues: days.map {
                ($0, DayContents(events: [], sampleIdentifiers: []))
            })
        }

        let outcome = try await uploader.send()

        // Scheduled rather than skipped: an empty day that was never sent has no
        // fingerprint to match, so it goes up as an empty day and says so.
        XCTAssertEqual(outcome, .scheduled(days: 1, unchanged: 0))
    }
}
