@testable import Efferent
import XCTest

/// The in-flight guard, which is what a stalled outbox is usually made of.
///
/// One send ships a batch and no more, so the next one is started from the
/// completion of the previous. That only works if every path out of `send`
/// releases the claim — an early return that keeps it held stops the outbox for
/// good, and it stops it at a round number, which reads like a server problem
/// rather than a client one.
final class UploaderTests: XCTestCase {
    private func makeUploader(store: Store, identifier: String) throws -> Uploader {
        try Uploader(
            // A session identifier per test: background sessions are global to
            // the process, and two tests sharing one would share its tasks.
            configuration: .init(sessionIdentifier: identifier),
            destination: Destination(
                endpoint: URL(string: "https://example.invalid")!,
                readingPublicKey: WireTests.readingPublicKey
            ),
            store: store,
            identity: DeviceIdentity()
        )
    }

    func testAnEmptyOutboxDoesNotHoldTheClaim() async throws {
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
}
