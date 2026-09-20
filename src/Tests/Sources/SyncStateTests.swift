@testable import Efferent
import XCTest

/// What the dial says, which is the whole of the everyday screen.
///
/// The figure on the face and the legend under it are the only two things a
/// person reads here, and each state has to be told apart from every other one
/// by them alone. Worth testing on its own because every defect found in this
/// screen so far has been a state drawn as another state, which compiles.
final class SyncStateTests: XCTestCase {
    private func made(
        pendingDays: Int = 0,
        sentDays: Int = 2638,
        lastUploadAt: Date? = Date(),
        paused: Bool = false,
        rereading: Bool = false,
        problem: String? = nil
    ) -> SyncState {
        SyncState(
            stats: Stats(
                pendingDays: pendingDays, stuckDays: 0, sentDays: sentDays,
                lastUploadAt: lastUploadAt, backfillReached: "2015-12-12"
            ),
            paused: paused,
            rereading: rereading,
            problem: problem,
            timeLeft: nil,
            progress: 0.5
        )
    }

    /// Pressing start marks the last week before it knows which of those days
    /// differ, so the queue briefly holds days that are about to be written
    /// off. The face must not report them as work.
    func testARereadShowsNoFigure() {
        let state = made(pendingDays: 5, rereading: true)
        XCTAssertEqual(state.remaining, "—")
        XCTAssertEqual(state.caption, "reading health")
        XCTAssertFalse(state.settled)
    }

    /// The dash is a state, not a missing number, so it is said in words.
    func testARereadIsSpokenAsAState() {
        XCTAssertEqual(made(pendingDays: 5, rereading: true).spokenValue, "Reading Health")
    }

    /// A re-read that finds nothing is the ordinary end of pressing start, and
    /// it must land on the good state rather than on a nought.
    func testTheFigureComesBackWhenTheReadIsDone() {
        let state = made(pendingDays: 0, rereading: false)
        XCTAssertTrue(state.settled)
        XCTAssertEqual(state.caption, "every day is in the archive")
    }

    /// Days really waiting are still counted; the dash belongs to the moment
    /// before the phone knows, not to every moment.
    func testDaysWaitingAreCounted() {
        let state = made(pendingDays: 1284)
        // A thin space groups the thousands, not a comma and not a full space.
        XCTAssertEqual(state.remaining, "1\u{2009}284")
        XCTAssertFalse(state.settled)
        XCTAssertEqual(state.caption, "sending")
    }

    /// An error outranks a re-read: a phone that cannot send has something to
    /// say that matters more than what it is busy with.
    func testAProblemOutranksARereading() {
        let state = made(rereading: true, problem: "The archive refused the day.")
        XCTAssertEqual(state.problem, "The archive refused the day.")
        XCTAssertEqual(state.mood, .stopped)
    }

    /// Every caption is one line: the second line under the dial moved the
    /// figure above it, because the block is centred between two spacers.
    func testNoCaptionCarriesASecondLine() {
        for state in [made(), made(pendingDays: 5), made(paused: true), made(rereading: true)] {
            XCTAssertFalse(state.caption.contains("\n"))
        }
    }
}
