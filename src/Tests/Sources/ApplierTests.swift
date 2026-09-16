import CryptoKit
@testable import Efferent
import XCTest

/// The applier against a service made of dictionaries and a Health made of
/// arrays. What is worth testing is what happens between the edge cases: an
/// answer that did not land, an edit somebody else signed, a run that has to
/// stop halfway — and that in every one of them nothing is written twice and
/// nothing is lost.
final class ApplierTests: XCTestCase {
    static let bucket = "abcdefghijklmnopqrstuvwxyz"
    static let utc = Day.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    /// The service: a queue of sealed edits, and the outcomes it was handed.
    final class FakeService {
        struct Edit {
            let body: Data
            let headers: [String: String]
        }

        var queue: [(name: String, edit: Edit)] = []
        var outcomes: [String: [String: Any]] = [:]
        var outcomeStatus = 200
        var listings = 0
        var fetched: [String] = []
        var delay: UInt64 = 0

        func fetch(_ request: URLRequest) async throws -> Applier.Answer {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let path = request.url!.path
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if path.hasSuffix("/edits") {
                listings += 1
                let after = query.first { $0.name == "after" }?.value
                let limit = Int(query.first { $0.name == "limit" }?.value ?? "200")!
                let names = queue.map(\.name).sorted().filter { after == nil || $0 > after! }
                let page = Array(names.prefix(limit))
                let body = try JSONSerialization.data(withJSONObject: [
                    "edits": page.map { ["name": $0, "bytes": 1, "at": "x", "status": "pending"] },
                    "next": (page.count < names.count ? page.last! : NSNull()) as Any,
                ])
                return .init(status: 200, body: body, headers: [:])
            }
            if path.hasSuffix("/outcome") {
                let name = String(path.split(separator: "/")[3])
                XCTAssertNotNil(request.value(forHTTPHeaderField: "x-efferent-signature"))
                guard outcomeStatus == 200 else {
                    return .init(status: outcomeStatus, body: Data("{\"error\":\"no\"}".utf8), headers: [:])
                }
                outcomes[name] = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
                queue.removeAll { $0.name == name }
                return .init(status: 200, body: Data("{}".utf8), headers: [:])
            }
            let name = String(path.split(separator: "/").last!)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "x-efferent-writer"), "an unsigned fetch")
            fetched.append(name)
            guard let entry = queue.first(where: { $0.name == name }) else {
                return .init(status: 404, body: Data(), headers: [:])
            }
            return .init(status: 200, body: entry.edit.body, headers: entry.edit.headers)
        }
    }

    /// Health: one sample per id, and the days each one is on.
    final class FakeWriter: HealthWriter {
        var samples: [String: (put: EditItem.Put, version: Int)] = [:]
        var undecided = false
        var refuse: [String: OutcomeCode] = [:]
        var writes = 0

        func writeAccessUndecided() -> Bool {
            undecided
        }

        func apply(_ item: EditItem.Put, version: Int) async throws -> Written {
            writes += 1
            if let code = refuse[item.id] {
                throw WriteRefused.code(code)
            }
            // What stood under that id, before the new sample takes its place.
            let displaced = samples[item.id].map { [Self.record($0.put)] } ?? []
            samples[item.id] = (item, version)
            var days = Set(displaced.map(\.day))
            days.insert(Self.day(item.start))
            return Written(days: days, displaced: displaced)
        }

        func remove(id: String) async throws -> Written {
            guard let held = samples.removeValue(forKey: id) else { throw WriteRefused.code(.notFound) }
            let gone = Self.record(held.put)
            return Written(days: [gone.day], displaced: [gone])
        }

        static func record(_ put: EditItem.Put) -> DisplacedRecord {
            DisplacedRecord(
                metric: put.metric,
                start: Date(timeIntervalSince1970: TimeInterval(put.start)),
                end: Date(timeIntervalSince1970: TimeInterval(put.end)),
                value: put.value,
                unit: put.unit,
                stage: put.stage,
                day: day(put.start)
            )
        }

        static func day(_ seconds: Int64) -> String {
            Day.of(Date(timeIntervalSince1970: TimeInterval(seconds)), in: ApplierTests.utc)
        }
    }

    struct World {
        let reading = Curve25519.KeyAgreement.PrivateKey()
        let editor = Curve25519.Signing.PrivateKey()
        let service = FakeService()
        let writer = FakeWriter()
        let store: Store
        let destination: Destination
        var names = 0

        init() throws {
            store = try Store.inMemory()
            destination = try Destination(
                endpoint: XCTUnwrap(URL(string: "https://example.invalid")),
                readingPublicKey: reading.publicKey.rawRepresentation
            )
        }

        func applier(
            maxEdits: Int = Applier.maxEditsPerRun, calendar: Calendar = ApplierTests.utc
        ) -> Applier {
            Applier(
                destination: destination,
                identity: DeviceIdentity(),
                readingKey: { [reading] in reading },
                editorPublicKey: { [editor] in editor.publicKey.rawRepresentation },
                store: store,
                writer: writer,
                fetch: { [service] in try await service.fetch($0) },
                calendar: calendar,
                maxEdits: maxEdits
            )
        }

        /// Seal and sign an edit the way the agent does, and put it in the queue.
        @discardableResult
        mutating func submit(
            _ items: String,
            sealedTo: Curve25519.KeyAgreement.PublicKey? = nil,
            signedBy: Curve25519.Signing.PrivateKey? = nil
        ) throws -> String {
            names += 1
            let name = "175722840000\(names)-abcdefgh"
            let sealed = try SealedBox.seal(
                readingPublicKey: (sealedTo ?? reading.publicKey).rawRepresentation,
                plaintext: Deflate.compress(Data(#"{"v":1,"items":[\#(items)]}"#.utf8)),
                associatedData: CanonicalRequest.associatedData(editBucket: destination.bucket)
            )
            let signer = signedBy ?? editor
            let timestamp: Int64 = 1_757_300_000
            let signature = try signer.signature(for: CanonicalRequest.edit(
                bucket: destination.bucket, timestamp: timestamp, sealed: sealed
            ))
            service.queue.append((name, .init(body: sealed, headers: [
                "x-efferent-editor": Base64URL.encode(signer.publicKey.rawRepresentation),
                "x-efferent-signature": Base64URL.encode(Data(signature)),
                "x-efferent-timestamp": String(timestamp),
            ])))
            return name
        }
    }

    static let breakfast =
        #"{"op":"put","id":"agent:meal:1","metric":"dietaryEnergy","start":1757228400,"end":1757229300,"value":520,"unit":"kcal"}"#
    static let sleep =
        #"{"op":"put","id":"agent:sleep:1","metric":"sleep","start":1757196000,"end":1757221200,"stage":"asleepCore"}"#

    struct NotApplied: Error {}

    private func applied(_ outcome: Applier.Outcome) throws -> Applier.Applied {
        guard case let .applied(applied) = outcome else {
            XCTFail("expected an applied outcome, got \(outcome)")
            throw NotApplied()
        }
        return applied
    }

    // MARK: - The ordinary run

    func testEditsAreAppliedInOrderAndAnsweredWithTheirDays() async throws {
        var world = try World()
        let first = try world.submit(Self.breakfast + "," + Self.sleep)
        let second = try world.submit(#"{"op":"put","id":"agent:water:1","metric":"dietaryWater","start":1757228400,"end":1757228400,"value":250,"unit":"mL"}"#)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.edits, 2)
        XCTAssertEqual(outcome.items, 3)
        XCTAssertEqual(outcome.refused, 0)
        XCTAssertEqual(outcome.days, ["2025-09-07", "2025-09-06"])
        XCTAssertNil(outcome.stoppedBy)
        XCTAssertEqual(world.service.fetched, [first, second], "listing order")
        XCTAssertEqual(world.service.outcomes[first]?["applied"] as? Int, 2)
        XCTAssertEqual(world.service.outcomes[second]?["applied"] as? Int, 1)
        XCTAssertTrue(world.service.queue.isEmpty)
        XCTAssertEqual(
            world.writer.samples.keys.sorted(), ["agent:meal:1", "agent:sleep:1", "agent:water:1"]
        )
        XCTAssertEqual(try world.store.nextVersion(for: "agent:meal:1"), 2, "the version was drawn once and kept")
    }

    func testAnEmptyQueueIsNothingWaiting() async throws {
        let world = try World()
        let outcome = try await world.applier().run()
        XCTAssertEqual(outcome, .nothingWaiting)
        XCTAssertEqual(world.service.listings, 1)
    }

    // MARK: - When the answer does not land (DoD-5)

    func testAnAnswerThatDidNotLandLeavesTheEditToBeAppliedAgainWithAHigherVersion() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast)
        world.service.outcomeStatus = 502

        let first = try applied(await world.applier().run())
        XCTAssertNotNil(first.stoppedBy)
        XCTAssertEqual(first.edits, 0)
        XCTAssertEqual(first.days, ["2025-09-07"], "the meal was written, and its day is owed")
        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.version, 1)
        XCTAssertEqual(world.service.queue.map(\.name), [name], "the edit is still waiting")

        world.service.outcomeStatus = 200
        let second = try applied(await world.applier().run())
        XCTAssertEqual(second.edits, 1)
        XCTAssertEqual(world.writer.samples.count, 1, "one sample per id, however many times it was applied")
        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.version, 2)
        XCTAssertTrue(world.service.queue.isEmpty)
    }

    // MARK: - Edits the phone will not open

    func testAnEditSignedByAnotherKeyIsAnsweredBadSignatureAndLeavesTheQueue() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast, signedBy: Curve25519.Signing.PrivateKey())

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.edits, 1)
        XCTAssertEqual(outcome.refused, 1)
        XCTAssertTrue(world.writer.samples.isEmpty, "nothing was written")
        let refused = try XCTUnwrap(world.service.outcomes[name]?["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.first?["code"] as? String, "badSignature")
        XCTAssertEqual(refused.first?["item"] as? Int, 0)
        XCTAssertTrue(world.service.queue.isEmpty)
    }

    func testAnEditSealedToAnotherKeyIsAnsweredCannotOpen() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast, sealedTo: Curve25519.KeyAgreement.PrivateKey().publicKey)
        _ = try applied(await world.applier().run())
        let refused = try XCTUnwrap(world.service.outcomes[name]?["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.first?["code"] as? String, "cannotOpen")
    }

    func testAnEditThatIsNotABatchIsAnsweredMalformed() async throws {
        var world = try World()
        let name = try world.submit(#"{"op":"merge","id":"a"}"#)
        _ = try applied(await world.applier().run())
        let refused = try XCTUnwrap(world.service.outcomes[name]?["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.first?["code"] as? String, "malformed")
    }

    // MARK: - Items Health will not take

    func testARefusedItemIsAnsweredByIndexAndTheOthersStillLand() async throws {
        var world = try World()
        world.writer.refuse["agent:meal:1"] = .unauthorized
        let name = try world.submit(Self.breakfast + "," + Self.sleep + #",{"op":"delete","id":"nothing"}"#)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.items, 3)
        XCTAssertEqual(outcome.refused, 2)
        XCTAssertEqual(outcome.days, ["2025-09-06"])
        let refused = try XCTUnwrap(world.service.outcomes[name]?["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.map { $0["item"] as? Int }, [0, 2])
        XCTAssertEqual(refused.map { $0["code"] as? String }, ["unauthorized", "notFound"])
        XCTAssertEqual(world.service.outcomes[name]?["applied"] as? Int, 1)
    }

    // MARK: - What an agent may not do on its own

    /// Health holding the breakfast and the night, and a second edit that
    /// changes one and takes the other away. Returns the name of that second
    /// edit.
    private func changing(_ world: inout World) async throws -> String {
        try world.submit(Self.breakfast + "," + Self.sleep)
        _ = try applied(await world.applier().run())
        return try world.submit(
            #"{"op":"put","id":"agent:meal:1","metric":"dietaryEnergy","start":1757228400,"end":1757229300,"value":610,"unit":"kcal"}"#
                + #",{"op":"delete","id":"agent:sleep:1"}"#
        )
    }

    private func codes(_ world: World, of name: String) throws -> [String] {
        let refused = try XCTUnwrap(world.service.outcomes[name]?["refused"] as? [[String: Any]])
        return refused.compactMap { $0["code"] as? String }
    }

    /// Nothing waits for an answer. An agent reaches only what this app wrote,
    /// and what a change pushes out is kept so it can be put back.
    func testAChangeAndARemovalLandAtOnceAndKeepWhatTheyPushedOut() async throws {
        var world = try World()
        let name = try await changing(&world)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.items, 2)
        XCTAssertEqual(outcome.refused, 0)
        XCTAssertEqual(outcome.days, ["2025-09-07", "2025-09-06"])
        XCTAssertTrue(world.service.queue.isEmpty)
        XCTAssertEqual(world.service.outcomes[name]?["applied"] as? Int, 2)
        XCTAssertEqual(try codes(world, of: name), [])
        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.put.value, 610, "the change went in")
        XCTAssertNil(world.writer.samples["agent:sleep:1"], "the removal went through")

        let rows = try world.store.edits(of: name)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.displaced.first?.metric, "dietaryEnergy")
        XCTAssertEqual(rows.first?.displaced.first?.value, 520, "the meal it replaced")
        XCTAssertEqual(rows.first?.displaced.first?.day, "2025-09-07")
        XCTAssertEqual(rows.last?.displaced.first?.stage, "asleepCore", "the night it took away")
        XCTAssertTrue(rows.allSatisfy(\.canBeUndone), "both can be put back")
    }

    /// An addition pushed nothing out, so there is nothing to keep: undo takes
    /// the record away again, which is the whole of putting Health back.
    func testAnAdditionPushesNothingOutAndKeepsNothing() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        _ = try applied(await world.applier().run())

        let row = try XCTUnwrap(world.store.recentEdits().first)
        XCTAssertEqual(row.state, .applied)
        XCTAssertTrue(row.displaced.isEmpty)
        XCTAssertTrue(row.canBeUndone)
    }

    /// The version climbs on a change. HealthKit keeps the newest version it
    /// has seen for a sync identifier, so one that did not climb would leave
    /// the old sample standing and the write would vanish without a word.
    func testAChangeDrawsAFreshVersion() async throws {
        var world = try World()
        _ = try await changing(&world)
        _ = try applied(await world.applier().run())

        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.version, 2)
        XCTAssertEqual(try world.store.nextVersion(for: "agent:meal:1"), 3)
    }

    /// A row an older build wrote when a change still waited for an answer and
    /// the person said no. Nothing produces one any more, and a phone carrying
    /// one must not write the item after all: that would overwrite an answer
    /// nobody could give again.
    func testAnItemDeclinedByAnOlderBuildIsStillDeclined() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast)
        try world.store.recordEdit(
            .put(.init(
                id: "agent:meal:1", metric: "dietaryEnergy", start: 1_757_228_400,
                end: 1_757_229_300, value: 520, unit: "kcal", stage: nil
            )),
            at: 0, in: name, state: .declined, day: nil, code: .declined
        )

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.refused, 1)
        XCTAssertNil(world.writer.samples["agent:meal:1"], "Health was never asked")
        XCTAssertEqual(try codes(world, of: name), ["declined"])
    }

    // MARK: - Guards

    func testARunStopsAtItsShareAndTheRestWait() async throws {
        var world = try World()
        for _ in 0 ..< 3 {
            try world.submit(Self.breakfast)
        }
        let outcome = try applied(await world.applier(maxEdits: 2).run())
        XCTAssertEqual(outcome.edits, 2)
        XCTAssertEqual(world.service.queue.count, 1)
    }

    func testASecondRunWhileOneIsInFlightIsBusy() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        world.service.delay = 200_000_000
        let applier = world.applier()

        async let first = applier.run()
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await applier.run()
        XCTAssertEqual(second, .busy)
        _ = try applied(await first)
        XCTAssertEqual(world.service.listings, 1, "the busy run listed nothing")
    }

    func testNothingIsReadUntilThePersonHasBeenAsked() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        world.writer.undecided = true
        let outcome = try await world.applier().run()
        XCTAssertEqual(outcome, .notAsked)
        XCTAssertEqual(world.service.listings, 0)
        XCTAssertEqual(world.service.queue.count, 1)
    }

    func testAListingThatCannotBeReadThrowsAndTouchesNothing() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        world.service.queue[0].name = "../etc/passwd"
        do {
            _ = try await world.applier().run()
            XCTFail("ran")
        } catch let Applier.ApplyError.malformed(why) {
            XCTAssertTrue(why.contains("named"))
        }
        XCTAssertTrue(world.service.fetched.isEmpty)
    }
}
