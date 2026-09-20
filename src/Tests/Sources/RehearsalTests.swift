@testable import Efferent
import XCTest

/// The flags that let a simulator run the real path against a service on this
/// machine.
///
/// Worth testing because the whole point of them is that they are off: a build
/// that stood in for Apple without being asked would claim archives in the live
/// service on nobody's word, and nothing on screen would say so.
final class RehearsalTests: XCTestCase {
    func testNoFlagsLeaveTheBuildAsItIs() {
        XCTAssertNil(Rehearsal.deployment([]))
        XCTAssertFalse(Rehearsal.isPretending([]))
        XCTAssertFalse(Rehearsal.attester([]) is PretendedAttester)
    }

    /// The reading address follows the sending one. An agent handed the live
    /// address while the days went to this machine would open an archive that
    /// holds none of them.
    func testTheServiceFlagMovesBothAddresses() throws {
        let deployment = try XCTUnwrap(Rehearsal.deployment(["app", "--service", "http://localhost:8787"]))

        XCTAssertEqual(deployment.serviceURL.absoluteString, "http://localhost:8787")
        XCTAssertEqual(deployment.mcpBaseURL.absoluteString, "http://localhost:8787/mcp/b")
    }

    func testAFlagWithNothingAfterItIsIgnored() {
        XCTAssertNil(Rehearsal.deployment(["app", "--service"]))
    }

    func testAskingToPretendHandsOverAStandIn() {
        XCTAssertTrue(Rehearsal.isPretending(["app", "--pretend-attested"]))
        XCTAssertTrue(Rehearsal.attester(["app", "--pretend-attested"]) is PretendedAttester)
    }

    /// The stand-in has to produce the shape a claim travels in — a key
    /// identifier is 32 bytes on the wire — or the request never reaches the
    /// service that was told not to check it.
    func testTheStandInProducesAClaimShapedAttestation() async throws {
        let attestation = try await PretendedAttester().attest(challenge: Data("anything".utf8))

        XCTAssertEqual(attestation.keyId.count, 32)
        XCTAssertFalse(attestation.object.isEmpty)
    }
}
