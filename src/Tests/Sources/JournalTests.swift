@testable import Efferent
import XCTest

final class JournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func journal(cap: Int = 512 * 1024) -> Journal {
        Journal(url: directory.appendingPathComponent("journal.log"), cap: cap)
    }

    func testAnEntryCarriesItsCategoryAndItsWords() {
        let journal = journal()
        journal.note("upload", "the archive took 3 of 4 days")

        let line = journal.read()
        XCTAssertTrue(line.contains("upload"), line)
        XCTAssertTrue(line.contains("the archive took 3 of 4 days"), line)
        XCTAssertTrue(line.hasSuffix("\n"), "an entry has to end so the next one can begin")
    }

    /// The diary is read top to bottom, so it is written that way.
    func testEntriesStayInTheOrderTheyHappened() {
        let journal = journal()
        journal.note("app", "first")
        journal.note("app", "second")
        journal.note("app", "third")

        let lines = journal.read().split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("first"), String(lines[0]))
        XCTAssertTrue(lines[1].hasSuffix("second"), String(lines[1]))
        XCTAssertTrue(lines[2].hasSuffix("third"), String(lines[2]))
    }

    /// A message that wrapped would read as several entries with no time on
    /// them, which is worse than a long line.
    func testAMessageWithLineBreaksStaysOneEntry() {
        let journal = journal()
        journal.note("upload", "service answered 500:\nbucket is gone\n")

        XCTAssertEqual(journal.read().split(separator: "\n").count, 1)
    }

    /// The diary is capped, so a phone that has been retrying for a week does
    /// not fill up. What it keeps is the recent half — the part that explains
    /// what is happening now.
    func testAFullDiaryDropsItsOldestHalf() {
        let journal = journal(cap: 4 * 1024)
        for index in 1 ... 400 {
            journal.note("app", "entry number \(index)")
        }

        let text = journal.read()
        XCTAssertLessThan(text.count, 8 * 1024, "the diary grew past what it may keep")
        XCTAssertTrue(text.contains("entry number 400"), "the newest entry was dropped")
        XCTAssertFalse(text.contains("entry number 1 "), "the oldest entry was kept")
        XCTAssertFalse(
            text.hasPrefix("entry"), "the diary was cut in the middle of an entry"
        )
    }

    func testClearingLeavesNothingBehind() {
        let journal = journal()
        journal.note("app", "something happened")
        journal.clear()

        XCTAssertEqual(journal.read(), "")
    }

    /// Nothing may stop sending because the diary could not be written.
    func testAnUnwritableDiaryIsSilent() {
        let blocked = Journal(url: URL(fileURLWithPath: "/dev/null/journal.log"))
        blocked.note("app", "this goes nowhere")

        XCTAssertEqual(blocked.read(), "")
    }
}
