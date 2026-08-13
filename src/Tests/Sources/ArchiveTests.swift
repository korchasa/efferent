@testable import Efferent
import XCTest

/// Reading the archive's listing, which is the only evidence the device ever
/// gets that its own bookkeeping is true.
///
/// Two properties matter and both fail quietly if they are wrong. A walk that
/// stops at the first page reports most of an archive as absent. A walk that
/// fails halfway and answers with what it had does the same thing, but only
/// sometimes, and only when the network is bad.
final class ArchiveTests: XCTestCase {
    private func destination() throws -> Destination {
        try Destination(
            endpoint: XCTUnwrap(URL(string: "https://example.invalid")),
            readingPublicKey: WireTests.readingPublicKey
        )
    }

    /// A stand-in service holding `days`, answering pages of `pageSize` the way
    /// the real listing does — skipping *past* `after`.
    private func service(
        holding days: [String], pageSize: Int, asked: (@Sendable (URL) -> Void)? = nil
    ) -> @Sendable (URL) async throws -> Data {
        let sorted = days.sorted()
        return { url in
            asked?(url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let after = query.first { $0.name == "after" }?.value
            let remaining = sorted.filter { after == nil || $0 > after! }
            let page = Array(remaining.prefix(pageSize))
            let next = remaining.count > page.count ? page.last : nil

            var json = "{\"days\":["
            json += page.map { "{\"day\":\"\($0)\",\"bytes\":1,\"uploaded\":\"x\"}" }
                .joined(separator: ",")
            json += "],\"next\":" + (next.map { "\"\($0)\"" } ?? "null") + "}"
            return Data(json.utf8)
        }
    }

    private func days(_ count: Int, from: String = "2020-01-01") throws -> [String] {
        var days: [String] = []
        var current = from
        while days.count < count {
            days.append(current)
            current = try Day.next(current, in: Day.calendar())
        }
        return days
    }

    func testAnEmptyArchiveIsAnEmptyAnswerRatherThanAFailure() async throws {
        let archive = try Archive(destination: destination(), fetch: service(holding: [], pageSize: 10))

        let held = try await archive.days()

        XCTAssertTrue(held.isEmpty)
    }

    /// The one that matters. A decade is several pages, and a reader that took
    /// the first would call everything after it missing — then hand the device
    /// a reason to re-upload years of history it already had.
    func testTheWalkFollowsEveryPageToTheEnd() async throws {
        let all = try days(2500)
        let counted = Counter()
        let archive = try Archive(
            destination: destination(),
            fetch: service(holding: all, pageSize: 400, asked: { _ in counted.bump() })
        )

        let held = try await archive.days()

        XCTAssertEqual(held.count, 2500)
        XCTAssertEqual(held, Set(all))
        XCTAssertEqual(counted.value, 7, "2500 days at 400 a page is seven requests")
    }

    /// A failure has to be a failure. Answering with the pages that did arrive
    /// would name the rest of the archive as lost, and the caller believes it.
    func testAPageThatFailsSinksTheWholeWalk() async throws {
        let all = try days(900)
        let underlying = service(holding: all, pageSize: 400)
        let archive = try Archive(destination: destination()) { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "after" }) {
                throw Archive.ArchiveError.refused(status: 503)
            }
            return try await underlying(url)
        }

        do {
            let held = try await archive.days()
            XCTFail("a broken walk answered with \(held.count) days instead of failing")
        } catch {
            XCTAssertEqual(error as? Archive.ArchiveError, .refused(status: 503))
        }
    }

    func testAnAnswerThatIsNotAListingIsRefused() async throws {
        let archive = try Archive(destination: destination()) { _ in Data("not json".utf8) }

        do {
            _ = try await archive.days()
            XCTFail("nonsense parsed as a listing")
        } catch {
            guard case .malformed = error as? Archive.ArchiveError else {
                return XCTFail("expected a malformed listing, got \(error)")
            }
        }
    }

    /// A service that always offers another page would otherwise walk forever,
    /// on a phone, holding up every upload behind it.
    func testAListingThatNeverEndsIsCutOffLoudly() async throws {
        let archive = try Archive(destination: destination()) { _ in
            Data(#"{"days":[{"day":"2020-01-01","bytes":1,"uploaded":"x"}],"next":"2020-01-01"}"#.utf8)
        }

        do {
            _ = try await archive.days()
            XCTFail("the walk never stopped")
        } catch {
            XCTAssertEqual(error as? Archive.ArchiveError, .tooManyPages)
        }
    }
}

/// Counts calls from inside a `@Sendable` closure without tripping concurrency
/// checking.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
