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
        /// The read key "the phone registered": a listing has to be signed with
        /// it, the way the service insists once there is one.
        var reader: Curve25519.Signing.PublicKey?
        var bucket = ""

        func fetch(_ request: URLRequest) async throws -> Applier.Answer {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let path = request.url!.path
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if path.hasSuffix("/edits") {
                listings += 1
                if let reader {
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "x-efferent-reader"),
                        Base64URL.encode(reader.rawRepresentation),
                        "the queue was listed without the read key"
                    )
                    let signature = Base64URL.decode(request.value(forHTTPHeaderField: "x-efferent-signature") ?? "")
                    let stamp = Int64(request.value(forHTTPHeaderField: "x-efferent-timestamp") ?? "") ?? 0
                    XCTAssertTrue(
                        reader.isValidSignature(signature, for: CanonicalRequest.read(
                            bucket: bucket, target: ReadKey.target(of: request.url!), timestamp: stamp
                        )),
                        "the listing's signature does not cover the listing"
                    )
                }
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
                throw WriteFailed.code(code)
            }
            // What stood under that id, before the new sample takes its place.
            let displaced = samples[item.id].map { [Self.record($0.put)] } ?? []
            samples[item.id] = (item, version)
            var days = Set(displaced.map(\.day))
            days.insert(Self.day(item.start))
            return Written(days: days, displaced: displaced)
        }

        func remove(id: String) async throws -> Written {
            guard let held = samples.removeValue(forKey: id) else { throw WriteFailed.code(.notFound) }
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
            service.reader = try ReadKey.derive(from: reading).publicKey
            service.bucket = destination.bucket
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
            signedBy: Curve25519.Signing.PrivateKey? = nil,
            signedAt timestamp: Int64 = 1_757_300_000
        ) throws -> String {
            names += 1
            let name = "175722840000\(names)-abcdefgh"
            let sealed = try SealedBox.seal(
                readingPublicKey: (sealedTo ?? reading.publicKey).rawRepresentation,
                plaintext: Deflate.compress(Data(#"{"v":1,"items":[\#(items)]}"#.utf8)),
                associatedData: CanonicalRequest.associatedData(editBucket: destination.bucket)
            )
            let signer = signedBy ?? editor
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
    static let water =
        #"{"op":"put","id":"agent:water:1","metric":"dietaryWater","start":1757228400,"end":1757228400,"value":250,"unit":"mL"}"#
    static let correctedBreakfast =
        #"{"op":"put","id":"agent:meal:1","metric":"dietaryEnergy","start":1757228400,"end":1757229300,"value":610,"unit":"kcal"}"#

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
        let second = try world.submit(Self.water)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.edits, 2)
        XCTAssertEqual(outcome.items, 3)
        XCTAssertEqual(outcome.failed, 0)
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

    // MARK: - A locked phone (DELIVERY-12)

    func testALockedPhoneListsTheQueueAndWritesNothing() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        try world.submit(Self.sleep)

        let outcome = try await world.applier().run(canWrite: false)

        XCTAssertEqual(outcome, .locked(waiting: 2), "the count is what the unlock will land")
        XCTAssertEqual(world.service.listings, 1, "the queue was reached")
        XCTAssertTrue(world.writer.samples.isEmpty, "Health is sealed")
        XCTAssertEqual(world.service.outcomes.count, 0, "an unanswered edit stays in the queue")
    }

    func testTheSameEditsLandOnceTheLockIsOff() async throws {
        var world = try World()
        try world.submit(Self.breakfast)

        _ = try await world.applier().run(canWrite: false)
        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.edits, 1)
        XCTAssertEqual(outcome.items, 1, "nothing was lost to the locked run")
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
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertTrue(world.writer.samples.isEmpty, "nothing was written")
        let failed = try XCTUnwrap(world.service.outcomes[name]?["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.first?["code"] as? String, "badSignature")
        XCTAssertEqual(failed.first?["item"] as? Int, 0)
        XCTAssertTrue(world.service.queue.isEmpty)
    }

    func testAnEditSealedToAnotherKeyIsAnsweredCannotOpen() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast, sealedTo: Curve25519.KeyAgreement.PrivateKey().publicKey)
        _ = try applied(await world.applier().run())
        let failed = try XCTUnwrap(world.service.outcomes[name]?["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.first?["code"] as? String, "cannotOpen")
    }

    func testAnEditThatIsNotABatchIsAnsweredMalformed() async throws {
        var world = try World()
        let name = try world.submit(#"{"op":"merge","id":"a"}"#)
        _ = try applied(await world.applier().run())
        let failed = try XCTUnwrap(world.service.outcomes[name]?["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.first?["code"] as? String, "malformed")
    }

    // MARK: - Items Health will not take

    func testAFailedItemIsAnsweredByIndexAndTheOthersStillLand() async throws {
        var world = try World()
        world.writer.refuse["agent:meal:1"] = .unauthorized
        let name = try world.submit(Self.breakfast + "," + Self.sleep + #",{"op":"delete","id":"nothing"}"#)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.items, 3)
        XCTAssertEqual(outcome.failed, 2)
        XCTAssertEqual(outcome.days, ["2025-09-06"])
        let failed = try XCTUnwrap(world.service.outcomes[name]?["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.map { $0["item"] as? Int }, [0, 2])
        XCTAssertEqual(failed.map { $0["code"] as? String }, ["unauthorized", "notFound"])
        XCTAssertEqual(world.service.outcomes[name]?["applied"] as? Int, 1)
    }

    // MARK: - What an agent may not do on its own

    /// Health holding the breakfast and the night, and a second edit that
    /// changes one and takes the other away. Returns the name of that second
    /// edit.
    private func changing(_ world: inout World) async throws -> String {
        try world.submit(Self.breakfast + "," + Self.sleep)
        _ = try applied(await world.applier().run())
        return try world.submit(Self.correctedBreakfast + #",{"op":"delete","id":"agent:sleep:1"}"#)
    }

    private func codes(_ world: World, of name: String) throws -> [String] {
        let failed = try XCTUnwrap(world.service.outcomes[name]?["failed"] as? [[String: Any]])
        return failed.compactMap { $0["code"] as? String }
    }

    /// Nothing waits for an answer. An agent reaches only what this app wrote,
    /// and what a change pushes out is kept so it can be put back.
    func testAChangeAndARemovalLandAtOnceAndKeepWhatTheyPushedOut() async throws {
        var world = try World()
        let name = try await changing(&world)

        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.items, 2)
        XCTAssertEqual(outcome.failed, 0)
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
        XCTAssertTrue(rows.allSatisfy(\.personCanAct), "the person can act on both")
    }

    /// An addition pushed nothing out, so there is nothing to keep: undo takes
    /// the record away again, which is the whole of putting Health back.
    func testAnAdditionPushesNothingOutAndKeepsNothing() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        _ = try applied(await world.applier().run())

        let row = try XCTUnwrap(world.store.recentEdits().first)
        XCTAssertEqual(row.state, .written)
        XCTAssertTrue(row.displaced.isEmpty)
        XCTAssertTrue(row.personCanAct)
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

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertNil(world.writer.samples["agent:meal:1"], "Health was never asked")
        XCTAssertEqual(try codes(world, of: name), ["declined"])
    }

    // MARK: - An answered edit, listed again (DELIVERY-3a)

    /// The service deletes an edit when it takes the answer. One that lists it
    /// again under a fresh name must not have it applied twice: by then a later
    /// edit has corrected the meal, and the replay would put the old value back.
    func testAnEditServedAgainUnderANewNameIsNotAppliedTwice() async throws {
        var world = try World()
        try world.submit(Self.breakfast)
        let original = try XCTUnwrap(world.service.queue.first?.edit)
        _ = try applied(await world.applier().run())
        try world.submit(Self.correctedBreakfast)
        _ = try applied(await world.applier().run())
        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.put.value, 610)
        let writes = world.writer.writes

        let renamed = "1757228499999-zzzzzzzz"
        world.service.queue.append((renamed, original))
        let outcome = try applied(await world.applier().run())

        XCTAssertEqual(outcome.edits, 1)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(world.writer.writes, writes, "Health was not asked again")
        XCTAssertEqual(world.writer.samples["agent:meal:1"]?.put.value, 610, "the correction stands")
        XCTAssertEqual(try codes(world, of: renamed), ["replayed"])
        XCTAssertEqual(world.service.outcomes[renamed]?["applied"] as? Int, 0)
        XCTAssertTrue(world.service.queue.isEmpty, "a replay is answered, and leaves the queue")
        XCTAssertEqual(try world.store.edits(of: renamed).first?.code, .replayed, "and the journal says so")
    }

    /// The same, under the name it was answered as: a service that took the
    /// answer and did not delete the edit.
    func testAnAnsweredEditServedAgainUnderItsOwnNameIsNotApplied() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast)
        let original = try XCTUnwrap(world.service.queue.first?.edit)
        _ = try applied(await world.applier().run())
        let writes = world.writer.writes

        world.service.queue.append((name, original))
        _ = try applied(await world.applier().run())

        XCTAssertEqual(world.writer.writes, writes, "Health was not asked again")
        XCTAssertEqual(try codes(world, of: name), ["replayed"])
        // What the edit did the first time stays the journal's account of it.
        let rows = try world.store.edits(of: name)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .written)
        XCTAssertNil(rows.first?.code)
    }

    /// Bytes the phone has let go of are caught by their moment instead. Two
    /// edits the service took in order are signed at most ten minutes apart, so
    /// one signed sixteen minutes before an edit already answered was answered
    /// long ago — and one ten minutes before is an ordinary queue.
    func testAnEditSignedLongBeforeTheNewestAnsweredOneIsNotApplied() async throws {
        var world = try World()
        try world.submit(Self.breakfast, signedAt: 1_757_300_000)
        _ = try applied(await world.applier().run())

        let stale = try world.submit(Self.sleep, signedAt: 1_757_300_000 - 960)
        let close = try world.submit(Self.water, signedAt: 1_757_300_000 - 600)
        _ = try applied(await world.applier().run())

        XCTAssertEqual(try codes(world, of: stale), ["replayed"])
        XCTAssertNil(world.writer.samples["agent:sleep:1"])
        XCTAssertEqual(try codes(world, of: close), [])
        XCTAssertNotNil(world.writer.samples["agent:water:1"])
    }

    /// An answer that did not land is not an answer: the edit stays in the
    /// queue and is applied again, and nothing about that is a replay.
    func testAnEditWhoseAnswerDidNotLandIsNotTakenForAReplay() async throws {
        var world = try World()
        let name = try world.submit(Self.breakfast)
        world.service.outcomeStatus = 502
        _ = try applied(await world.applier().run())
        XCTAssertNil(try world.store.answeredEdit(digest: Data(SHA256.hash(data: world.service.queue[0].edit.body))))

        world.service.outcomeStatus = 200
        _ = try applied(await world.applier().run())

        XCTAssertEqual(try codes(world, of: name), [])
        XCTAssertEqual(world.service.outcomes[name]?["applied"] as? Int, 1)
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
