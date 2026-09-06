import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// The store screenshots, rendered by the app itself.
///
/// `--snapshot <directory>` on the command line makes the launch render three
/// screens offscreen at the 6.7-inch store size (1290 × 2796) and quit. Nothing
/// real is touched: the screens are fed a `Services` built on an in-memory store
/// with figures chosen to show each state, and the archive in the prompt is a
/// key made up on the spot. Reproducible, permission-free, and it needs no phone
/// — which matters here, because a real archive can be created only on one.
@MainActor
enum Snapshot {
    /// Points, times three for the 6.7-inch class: 430 × 932 → 1290 × 2796.
    private static let size = CGSize(width: 430, height: 932)
    private static let scale: CGFloat = 3

    static func runIfAsked() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else {
            return false
        }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        do {
            try render(into: directory)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    private static func render(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fresh = Services(
            demoStats: nil, batchTotal: 0, setupComplete: false,
            deployment: nil, destination: nil, handoff: nil
        )
        let sending = try Self.sending()

        let screens: [(name: String, view: AnyView)] = [
            ("01-welcome", AnyView(SetupView().environmentObject(fresh))),
            ("02-sending", AnyView(HomeView().environmentObject(sending))),
            ("03-connect", AnyView(ConnectScreen().environmentObject(sending))),
        ]
        for screen in screens {
            let renderer = ImageRenderer(content: screen.view.frame(width: size.width, height: size.height))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(size)
            guard let image = renderer.uiImage, let png = image.pngData() else {
                throw SnapshotError.notRendered(screen.name)
            }
            try png.write(to: directory.appendingPathComponent("\(screen.name).png"))
        }
    }

    /// A phone a third of the way through its first export, with a decade of
    /// Health behind it and an archive nobody has connected yet.
    private static func sending() throws -> Services {
        let deployment = try Deployment(
            serviceURL: URL(string: "https://efferent.korchasa.dev")!,
            mcpBaseURL: URL(string: "https://efferent.korchasa.dev/mcp/b")!
        )
        let reading = Curve25519.KeyAgreement.PrivateKey()
        let destination = try Destination(
            endpoint: deployment.serviceURL, readingPublicKey: reading.publicKey.rawRepresentation
        )
        let handoff = ConnectionHandoff(
            deployment: deployment, destination: destination, privateKey: reading.rawRepresentation
        )
        let stats = Stats(
            pendingDays: 1284, stuckDays: 0, sentDays: 2638,
            lastUploadAt: Date(), backfillReached: "2015-12-12"
        )
        return Services(
            demoStats: stats, batchTotal: 3922, setupComplete: true,
            deployment: deployment, destination: destination, handoff: handoff
        )
    }
}

enum SnapshotError: Error {
    case notRendered(String)
}

/// The connect sheet as a whole screen: the same content, under a title row of
/// its own, because an image renderer presents nothing.
private struct ConnectScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Connect your agent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(height: 52)
            ConnectContent(done: {}, scrolls: false)
        }
        .pageBackground()
    }
}
