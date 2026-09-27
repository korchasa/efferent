import Foundation

/// A run against a service on this machine, with Apple's word stood in for.
///
/// App Attest is hardware. A simulator has none, so the claim that creates an
/// archive is refused there and every screen behind it — the dial, the journal,
/// what an agent changed — can only be looked at with the made-up figures
/// `--demo` hands over. That is enough for a walk over the layout and nothing
/// like enough for the path this app exists to run: read Health, seal a day,
/// send it, hear what the archive says.
///
/// Two command-line flags open that path against a service running on the same
/// machine, and the stand-in exists in debug builds alone — a release binary
/// carries none, so there is nothing in it to switch on:
///
///     --service http://localhost:8787   where to send instead of the build's address
///     --pretend-attested                claim without asking Apple
///
/// The service has to agree, and only a copy on loopback will: a development
/// copy started with unattested claims switched on is the one that takes such a
/// claim, and the live service refuses it whatever it is told, because a Worker
/// with a route never answers at a loopback address.
enum Rehearsal {
    /// Where this run sends, when the command line named somewhere.
    ///
    /// The reading endpoint follows the same host: a handoff that pointed at
    /// the live service while the days went somewhere else would hand an agent
    /// an address holding none of them.
    static func deployment(_ arguments: [String] = CommandLine.arguments) -> Deployment? {
        #if DEBUG
        guard let address = value(after: "--service", in: arguments),
              let service = URL(string: address),
              let reader = URL(string: address + "/mcp/b")
        else { return nil }
        return try? Deployment(serviceURL: service, mcpBaseURL: reader)
        #else
        nil
        #endif
    }

    /// What proves the caller is this app on a real iPhone, or a stand-in when
    /// the command line asked for one.
    static func attester(_ arguments: [String] = CommandLine.arguments) -> Attesting {
        isPretending(arguments) ? PretendedAttester() : DeviceAttester()
    }

    /// Whether this run stands in for Apple, which the log says out loud.
    static func isPretending(_ arguments: [String] = CommandLine.arguments) -> Bool {
        #if DEBUG
        arguments.contains("--pretend-attested")
        #else
        false
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
        return arguments[at + 1]
    }
}

/// An attestation that proves nothing, for a service that has been told not to
/// ask. The bytes are what a claim needs to travel at all; the service on the
/// other side skips the check before it reads them.
///
/// It is never reached in a release build: `Rehearsal.isPretending` is a
/// compile-time `false` there, so nothing constructs one.
struct PretendedAttester: Attesting {
    var isAvailable: Bool { true }

    func attest(challenge _: Data) async throws -> Attestation {
        Attestation(object: Data("pretended".utf8), keyId: Data(repeating: 0, count: 32))
    }
}
