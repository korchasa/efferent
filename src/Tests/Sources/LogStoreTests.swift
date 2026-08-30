@testable import Efferent
import XCTest

final class LogStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(cap: Int = 512 * 1024) -> LogStore {
        LogStore(url: directory.appendingPathComponent("efferent.log"), cap: cap)
    }

    func testAnEntryCarriesItsLevelItsCategoryAndItsWords() {
        let log = store()
        log.note("INFO ", "upload", "the archive took 3 of 4 days")

        let line = log.read()
        XCTAssertTrue(line.contains("INFO"), line)
        XCTAssertTrue(line.contains("upload"), line)
        XCTAssertTrue(line.contains("the archive took 3 of 4 days"), line)
        XCTAssertTrue(line.hasSuffix("\n"), "an entry has to end so the next one can begin")
    }

    /// A line is read by eye and by grep, so the level comes before the words
    /// and always in the same place.
    func testTheLevelComesBeforeTheCategory() {
        let log = store()
        log.note("ERROR", "upload", "request 7 answered 500")

        let line = log.read()
        let level = try? XCTUnwrap(line.range(of: "ERROR"))
        let category = try? XCTUnwrap(line.range(of: "upload"))
        XCTAssertNotNil(level)
        XCTAssertNotNil(category)
        if let level, let category {
            XCTAssertLessThan(level.lowerBound, category.lowerBound, line)
        }
    }

    /// The log is read top to bottom, so it is written that way.
    func testEntriesStayInTheOrderTheyHappened() {
        let log = store()
        log.note("INFO ", "app", "first")
        log.note("DEBUG", "app", "second")
        log.note("ERROR", "app", "third")

        let lines = log.read().split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("first"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix("second"), String(lines[1]))
        XCTAssertTrue(lines[2].hasSuffix("third"), String(lines[2]))
    }

    /// A message that wrapped would read as several entries with no time on
    /// them, which is worse than a long line.
    func testAMessageWithLineBreaksStaysOneEntry() {
        let log = store()
        log.note("ERROR", "upload", "service answered 500:\nbucket is gone\n")

        XCTAssertEqual(log.read().split(separator: "\n").count, 1)
    }

    /// The log is capped, so a phone that has been retrying for a week does
    /// not fill up. What it keeps is the recent half — the part that explains
    /// what is happening now.
    func testAFullLogDropsItsOldestHalf() {
        let log = store(cap: 4 * 1024)
        for index in 1 ... 400 {
            log.note("DEBUG", "app", "entry number \(index)")
        }

        let text = log.read()
        XCTAssertLessThan(text.count, 8 * 1024, "the log grew past what it may keep")
        XCTAssertTrue(text.contains("entry number 400"), "the newest entry was dropped")
        XCTAssertFalse(text.contains("entry number 1 "), "the oldest entry was kept")
        XCTAssertFalse(
            text.hasPrefix("entry"), "the log was cut in the middle of an entry"
        )
    }

    func testClearingLeavesNothingBehind() {
        let log = store()
        log.note("INFO ", "app", "something happened")
        log.clear()

        XCTAssertEqual(log.read(), "")
    }

    /// Nothing may stop sending because the log could not be written.
    func testAnUnwritableLogIsSilent() {
        let blocked = LogStore(url: URL(fileURLWithPath: "/dev/null/efferent.log"))
        blocked.note("INFO ", "app", "this goes nowhere")

        XCTAssertEqual(blocked.read(), "")
    }
}
