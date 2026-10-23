#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import ApplicationServices
@testable import CabalmailUI

/// What `RowSwitch` tells VoiceOver it is, read through the accessibility
/// API itself rather than through the source.
///
/// The rules list's Enabled control looked and worked like a switch and
/// spoke as a **toggle button**, where every other pane's switch speaks as
/// a **switch** (#2040). The cause was `.labelsHidden()`, which no source
/// scan of the *style* could see and which `.accessibilityLabel` does not
/// undo — so the regression test has to ask the control what it is.
///
/// The window hosts three controls: `RowSwitch`, a plain labelled `Toggle`
/// (what the Notifications pane draws, the shape this one has to match)
/// and a `.labelsHidden()` toggle (the pre-fix shape). The last is the
/// oracle's own control: it must come back as `AXToggle`, or an empty or
/// uniform reading would let the first assertion pass for the wrong
/// reason.
final class RowSwitchAccessibilityTests: XCTestCase {

    private struct Harness: View {
        @State private var isOn = true

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                RowSwitch(label: "Enabled", isOn: $isOn)
                    .accessibilityIdentifier("rowSwitch")
                Toggle("Enabled", isOn: $isOn)
                    .miniSwitchStyleOnMac()
                    .accessibilityIdentifier("labelled")
                Toggle("Enabled", isOn: $isOn)
                    .labelsHidden()
                    .miniSwitchStyleOnMac()
                    .accessibilityIdentifier("labelsHidden")
            }
            .padding(20)
        }
    }

    /// One control's AX reading, by the identifier it was given.
    private struct Reading {
        var subrole = "-"
        var roleDescription = "-"
        var label = "-"
    }

    func testRowSwitchSpeaksAsASwitchAndKeepsItsName() throws {
        let readings = try hostAndRead()

        let hidden = try XCTUnwrap(readings["labelsHidden"], "the oracle read no controls at all")
        XCTAssertEqual(
            hidden.subrole, "AXToggle",
            """
            control: a .labelsHidden() toggle no longer reads as a toggle button, \
            so this test can no longer tell the defect from the fix
            """
        )

        let row = try XCTUnwrap(readings["rowSwitch"], "RowSwitch is absent from the accessibility tree")
        XCTAssertEqual(row.subrole, "AXSwitch", "RowSwitch reads as \\(row.roleDescription), not a switch (#2040)")
        XCTAssertEqual(row.roleDescription, "switch")
        XCTAssertEqual(row.label, "Enabled", "RowSwitch has no name for VoiceOver to read")

        // The sibling it has to match. It is nameless of its own accord —
        // its label is folded into the row, not the control — so RowSwitch
        // is the better-named of the two, never the worse.
        let labelled = try XCTUnwrap(readings["labelled"], "the labelled toggle is absent from the accessibility tree")
        XCTAssertEqual(labelled.subrole, "AXSwitch")
        XCTAssertEqual(row.subrole, labelled.subrole, "RowSwitch and a plain labelled switch disagree on what they are")
    }

    // MARK: - Oracle

    /// Hosts `Harness` in an off-screen window and reads this process's own
    /// accessibility tree. The read runs off the main queue — an AX query
    /// aimed at one's own process is answered on the main runloop, so
    /// asking from it deadlocks — and the window is torn down afterwards.
    private func hostAndRead() throws -> [String: Reading] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: Harness())
        window.orderFront(nil)

        var readings: [String: Reading] = [:]
        let done = expectation(description: "accessibility read")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            var found: [String: Reading] = [:]
            Self.walk(AXUIElementCreateApplication(getpid()), depth: 0, into: &found)
            readings = found
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return readings
    }

    private static func walk(_ element: AXUIElement, depth: Int, into found: inout [String: Reading]) {
        guard depth < 20 else { return }
        let identifier = string(element, "AXIdentifier")
        if !identifier.isEmpty, identifier != "-" {
            found[identifier] = Reading(
                subrole: string(element, kAXSubroleAttribute as String),
                roleDescription: string(element, kAXRoleDescriptionAttribute as String),
                label: string(element, kAXDescriptionAttribute as String)
            )
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, into: &found) }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }
}
#endif
