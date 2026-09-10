@testable import Efferent
import UIKit
import UniformTypeIdentifiers
import XCTest

/// What the phone actually hands over when the prompt is shared.
///
/// Worth testing because the failure is invisible from inside this app: the
/// prompt leaves as a string and the device on the other end decides what it
/// was. One beginning "Instruction:" was read as a URL scheme, and the person
/// AirDropping their archive got "There is no application set to open the URL
/// Instruction:%0AConnect%20the…" instead of it.
final class ShareSheetTests: XCTestCase {
    private let prompt = "Instruction:\nConnect the supplied Efferent MCP and call setup_guide first."

    private func sheet(_ item: TextToShare) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func testAirDropIsHandedAFileWithTheTextInIt() throws {
        let item = TextToShare(prompt, named: "efferent-setup.txt")
        defer { item.clean() }

        let file = try XCTUnwrap(
            item.activityViewController(sheet(item), itemForActivityType: .airDrop) as? URL
        )
        XCTAssertTrue(file.isFileURL, "a string is what the other device has to guess at")
        XCTAssertEqual(file.lastPathComponent, "efferent-setup.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), prompt)
    }

    func testEveryOtherWayOfSendingItGetsTheTextItself() {
        let item = TextToShare(prompt, named: "efferent-setup.txt")
        defer { item.clean() }
        let sheet = sheet(item)

        // A message, a note or the clipboard is meant to hold the prompt, not
        // an attachment nobody can paste to an agent.
        for activity in [UIActivity.ActivityType.message, .copyToPasteboard, .mail] {
            XCTAssertEqual(
                item.activityViewController(sheet, itemForActivityType: activity) as? String,
                prompt,
                "\(activity.rawValue) was handed something other than the prompt"
            )
        }
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: nil) as? String, prompt)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(sheet) as? String, prompt)
        // The type nobody has to guess at.
        XCTAssertEqual(
            item.activityViewController(sheet, dataTypeIdentifierForActivityType: nil),
            UTType.plainText.identifier
        )
    }

    func testTheFileDoesNotOutliveTheShareItExistsFor() throws {
        let item = TextToShare(prompt, named: "efferent-setup.txt")
        let file = try XCTUnwrap(
            item.activityViewController(sheet(item), itemForActivityType: .airDrop) as? URL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // It holds the keys that open the archive, so it is taken away as soon
        // as the sheet reports back — which is after the transfer, because that
        // same answer is what tells this app the prompt went somewhere.
        item.clean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
