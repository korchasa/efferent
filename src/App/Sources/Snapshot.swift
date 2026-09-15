import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// The store screenshots, rendered by the app itself.
///
/// `--snapshot <directory>` on the command line makes the launch render six
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
        sending.demonstrate(Self.run())
        let journal = sending.recentEdits()
        // The applied one, not the change waiting beside it under the same id:
        // this screen is the record that is in Health and the way back out of it.
        guard let lunch = journal.first(where: {
            $0.metric == "dietaryEnergy" && $0.state == .applied
        }) else {
            throw SnapshotError.notRendered("05-edit")
        }
        // In the store's own order, which is the order the person is asked in:
        // oldest first, and the items of one edit as the agent sent them.
        let waiting = sending.waitingEdits()
        guard !waiting.isEmpty else { throw SnapshotError.notRendered("06-waiting") }

        let screens: [(name: String, view: AnyView)] = [
            ("01-welcome", AnyView(SetupView().environmentObject(fresh))),
            ("02-sending", AnyView(HomeView().environmentObject(sending))),
            ("03-connect", AnyView(ConnectScreen().environmentObject(sending))),
            ("04-edits", AnyView(EditsScreen(journal: journal).environmentObject(sending))),
            ("05-edit", AnyView(EditScreen(entry: lunch, calendar: sending.calendar))),
            ("06-waiting", AnyView(ReviewScreen(waiting: waiting).environmentObject(sending))),
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
            serviceURL: URL(string: "https://api.efferentapp.com")!,
            mcpBaseURL: URL(string: "https://api.efferentapp.com/mcp/b")!
        )
        let reading = Curve25519.KeyAgreement.PrivateKey()
        let destination = try Destination(
            endpoint: deployment.serviceURL, readingPublicKey: reading.publicKey.rawRepresentation
        )
        // With an editor key, because a phone that has registered one is the
        // ordinary case and the instruction in the prompt names it. Without it
        // the rendered prompt tells the agent to keep a key it cannot see.
        let editor = Curve25519.Signing.PrivateKey()
        let handoff = ConnectionHandoff(
            deployment: deployment,
            destination: destination,
            privateKey: reading.rawRepresentation,
            editorPrivateKey: editor.rawRepresentation,
            editorPublicKey: editor.publicKey.rawRepresentation
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

    /// A day and a half of an agent's work, with one of each thing that can
    /// become of an item: written, taken back out, refused, a record the agent
    /// removed, and two it is waiting to be allowed to change. The instants are
    /// relative, so the list groups them under "today" and "yesterday" whenever
    /// the screenshots happen to be taken.
    private static func run() -> [Services.DemoEdit] {
        let calendar = Day.calendar()
        let morning = calendar.startOfDay(for: Date())
        let today = Day.of(morning, in: calendar)
        let before = morning.addingTimeInterval(-24 * 60 * 60)
        let yesterday = Day.of(before, in: calendar)
        func at(_ start: Date, _ hours: Double) -> Date {
            start.addingTimeInterval(hours * 3600)
        }
        func seconds(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970)
        }
        return [
            .init(
                item: .put(.init(
                    id: "agent:meal:1", metric: "dietaryEnergy",
                    start: seconds(at(morning, 13)), end: seconds(at(morning, 13.25)),
                    value: 520, unit: "kcal", stage: nil
                )),
                state: .applied, day: today, at: at(morning, 13.4)
            ),
            .init(
                item: .put(.init(
                    id: "agent:meal:2", metric: "dietaryProtein",
                    start: seconds(at(morning, 13)), end: seconds(at(morning, 13.25)),
                    value: 31, unit: "g", stage: nil
                )),
                state: .applied, day: today, at: at(morning, 13.4)
            ),
            .init(
                item: .put(.init(
                    id: "agent:sleep:1", metric: "sleep",
                    start: seconds(at(before, 23.5)), end: seconds(at(morning, 6.6)),
                    value: nil, unit: nil, stage: "asleepCore"
                )),
                state: .applied, day: yesterday, at: at(morning, 8.2)
            ),
            .init(
                item: .put(.init(
                    id: "agent:mass:1", metric: "bodyMass",
                    start: seconds(at(morning, 8)), end: seconds(at(morning, 8)),
                    value: 78.4, unit: "kg", stage: nil
                )),
                state: .applied, day: today, at: at(morning, 8.2)
            ),
            .init(
                item: .put(.init(
                    id: "agent:water:1", metric: "dietaryWater",
                    start: seconds(at(before, 21.6)), end: seconds(at(before, 21.6)),
                    value: 250, unit: "mL", stage: nil
                )),
                state: .undone, day: yesterday, at: at(before, 21.7)
            ),
            .init(
                item: .put(.init(
                    id: "agent:meal:3", metric: "dietaryCarbohydrates",
                    start: seconds(at(before, 19)), end: seconds(at(before, 19.25)),
                    value: 64, unit: "g", stage: nil
                )),
                state: .refused, code: .unauthorized, at: at(before, 21.7)
            ),
            .init(
                item: .delete(id: "agent:meal:0"),
                state: .deleted, day: yesterday, at: at(before, 9.1)
            ),
            // The two waiting ones: a meal the agent wants to correct, and a
            // record it wants to take away. Both would change what Health holds
            // now, so neither has been written.
            .init(
                item: .put(.init(
                    id: "agent:meal:1", metric: "dietaryEnergy",
                    start: seconds(at(morning, 13)), end: seconds(at(morning, 13.25)),
                    value: 610, unit: "kcal", stage: nil
                )),
                state: .waiting, day: today, code: .awaitingApproval, at: at(morning, 14.6)
            ),
            .init(
                item: .delete(id: "agent:mass:1"),
                state: .waiting, day: today, code: .awaitingApproval, at: at(morning, 14.6)
            ),
        ]
    }
}

enum SnapshotError: Error {
    case notRendered(String)
}

/// The journal as a whole screen: the same rows under a title row of its own,
/// because an image renderer presents no navigation.
private struct EditsScreen: View {
    let journal: [EditEntry]

    var body: some View {
        VStack(spacing: 0) {
            Text("Agent edits")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(height: 52)
            EditsView(showing: journal, flat: true)
        }
        .pageBackground()
    }
}

/// One edit as a whole screen: the same content under a title row of its own,
/// because an image renderer presents no navigation.
private struct EditScreen: View {
    let entry: EditEntry
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(height: 52)
            EditDetailView(entry: entry, calendar: calendar, remove: {}, scrolls: false)
        }
        .pageBackground()
    }
}

/// The question as a whole screen: the same content under a title row of its
/// own, because an image renderer presents no navigation.
private struct ReviewScreen: View {
    let waiting: [EditEntry]

    var body: some View {
        VStack(spacing: 0) {
            Text("Waiting for you")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(height: 52)
            EditReviewView(showing: waiting, scrolls: false)
        }
        .pageBackground()
    }
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
