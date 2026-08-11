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
        let events = try [Event(id: "a", payload: Event.payload(["v": "1"]))]
        let digest = try Data(SHA256.hash(data: NDJSON.body(events)))
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

    // MARK: - Cutting a pass into requests

    private func sending(_ day: String, bytes: Int = 1) -> Uploader.Sending {
        Uploader.Sending(
            day: day, digest: Data(), identifiers: [], blob: Data(repeating: 0xAB, count: bytes)
        )
    }

    private func days(_ count: Int, from: String = "2026-01-01") throws -> [String] {
        var days: [String] = []
        var current = from
        while days.count < count {
            days.append(current)
            current = try Day.next(current, in: Day.calendar())
        }
        return days
    }

    /// The whole point of a batch: a pass that used to be a request per day is
    /// now one request, and every day is still in exactly one of them.
    func testAPassGoesAsWholeRequestsAndLosesNoDay() throws {
        let pending = try days(40).map { sending($0) }

        let batches = Uploader.batches(pending, configuration: .init())

        XCTAssertEqual(batches.map(\.count), [31, 9])
        XCTAssertEqual(
            batches.flatMap { $0 }.map(\.day).sorted(),
            pending.map(\.day).sorted(),
            "a day fell out between two requests"
        )
    }

    /// Days ascend inside a frame, and a frame that did not would be refused
    /// outright — the phone would stop sending with a 400 it cannot fix.
    func testDaysAreOrderedWithinARequest() throws {
        let pending = ["2026-03-01", "2026-01-05", "2026-02-09"].map { sending($0) }

        let batch = try XCTUnwrap(Uploader.batches(pending, configuration: .init()).first)

        XCTAssertEqual(batch.map(\.day), ["2026-01-05", "2026-02-09", "2026-03-01"])
    }

    func testABatchIsCutShortWhenItGetsTooLarge() throws {
        let pending = try days(6).map { sending($0, bytes: 400) }

        let batches = Uploader.batches(
            pending, configuration: .init(bytesPerRequest: 1000)
        )

        XCTAssertEqual(batches.map(\.count), [2, 2, 2])
    }

    /// There is no size at which a day stops being owed. A limit that held one
    /// back would leave it marked for good, and the counters would keep saying
    /// there is something waiting without ever getting rid of it.
    func testADayLargerThanTheLimitTravelsOnItsOwnRatherThanNotAtAll() {
        let pending = [
            sending("2026-01-01", bytes: 10),
            sending("2026-01-02", bytes: 5000),
            sending("2026-01-03", bytes: 10),
        ]

        let batches = Uploader.batches(pending, configuration: .init(bytesPerRequest: 1000))

        XCTAssertEqual(batches.map { $0.map(\.day) }, [
            ["2026-01-01"], ["2026-01-02"], ["2026-01-03"],
        ])
    }
}
