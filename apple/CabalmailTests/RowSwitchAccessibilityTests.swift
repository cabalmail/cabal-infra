#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import ApplicationServices
import os
@testable import CabalmailUI

/// What `RowSwitch` tells VoiceOver it is, read through the accessibility
/// API itself rather than through the source, and how much of its row it
/// takes, read from the layout.
///
/// The rules list's Enabled control looked and worked like a switch and
/// spoke as a **toggle button**, where every other pane's switch speaks as
/// a **switch** (#2040). The cause was `.labelsHidden()`, which no source
/// scan of the *style* could see and which `.accessibilityLabel` does not
/// undo — so the regression test has to ask the control what it is.
///
/// The first fix for that kept a `Text` label squeezed to no width, and a
/// grouped form, the container every `RowSwitch` lives in, stretches a
/// labelled toggle across its row: the rule row's summary lost half its
/// width, so its chevron landed mid-row, and the wrapped label made the row
/// seven lines tall. An accessibility reading cannot see that (the switch
/// element is the same 36×16 either way), so the window also records each
/// row's layout.
///
/// The window hosts a grouped `Form` of three rows in the Mac rule row's
/// shape: `RowSwitch`, a plain labelled `Toggle` (what the Notifications
/// pane draws, the shape this one has to speak as) and a `.labelsHidden()`
/// toggle (the pre-#2040 shape, which drew right and spoke wrong). The
/// last is the oracle's own control: it must come back as `AXToggle`, or an
/// empty or uniform reading would let the first assertion pass for the
/// wrong reason.
final class RowSwitchAccessibilityTests: XCTestCase {

    /// Each row's frame and its summary's, by the identifier of the row's
    /// switch, as the layout last reported them.
    private final class Layout {
        var rows: [String: CGRect] = [:]
        var summaries: [String: CGRect] = [:]
    }

    private struct Harness: View {
        let layout: Layout
        @State private var isOn = true

        var body: some View {
            Form {
                row("rowSwitch") { RowSwitch(label: "Enabled", isOn: $isOn) }
                row("labelled") {
                    Toggle("Enabled", isOn: $isOn)
                        .miniSwitchStyleOnMac()
                }
                row("labelsHidden") {
                    Toggle("Enabled", isOn: $isOn)
                        .labelsHidden()
                        .miniSwitchStyleOnMac()
                }
            }
            .formStyle(.grouped)
        }

        /// A Mac rule row (`RuleRow`): the summary that takes the rest,
        /// then the switch.
        private func row<Content: View>(_ id: String, @ViewBuilder _ content: () -> Content) -> some View {
            HStack(spacing: 12) {
                Text("rule summary")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.summaries[id] = $0 }
                content().accessibilityIdentifier(id)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.rows[id] = $0 }
        }
    }

    /// One control's AX reading, by the identifier it was given.
    private struct Reading {
        var subrole = "-"
        var roleDescription = "-"
        var label = "-"
        var minX = CGFloat.nan
    }

    @MainActor
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
        XCTAssertEqual(row.subrole, "AXSwitch", "RowSwitch reads as " + row.roleDescription + ", not a switch (#2040)")
        XCTAssertEqual(row.roleDescription, "switch")
        XCTAssertEqual(row.label, "Enabled", "RowSwitch has no name for VoiceOver to read")

        // The sibling it has to match. It is nameless of its own accord —
        // its label is folded into the row, not the control — so RowSwitch
        // is the better-named of the two, never the worse.
        let labelled = try XCTUnwrap(readings["labelled"], "the labelled toggle is absent from the accessibility tree")
        XCTAssertEqual(labelled.subrole, "AXSwitch")
        XCTAssertEqual(row.subrole, labelled.subrole, "RowSwitch and a plain labelled switch disagree on what they are")
    }

    /// The label that names the switch must take none of the row. The
    /// `.labelsHidden()` row in the same form is the reference: `RowSwitch`'s
    /// row is as tall as it, its summary as wide, and its switch where it
    /// is. The labelled toggle, which the form stretches across its row, is
    /// the control: without it the comparison could not tell that this form
    /// stretches a switch at all. The height has no such control, since only
    /// a wrapped label grows the row; a run against that label (row 112 pt
    /// against 16, summary 174 pt against 312) is what showed it fails.
    @MainActor
    func testRowSwitchTakesNoMoreOfTheRowThanTheSwitchItDraws() throws {
        let layout = Layout()
        let readings = try hostAndRead(layout)
        let row = try XCTUnwrap(layout.rows["rowSwitch"], "RowSwitch's row reported no layout")
        let hidden = try XCTUnwrap(layout.rows["labelsHidden"], "the reference row reported no layout")
        let summary = try XCTUnwrap(layout.summaries["rowSwitch"])
        let hiddenSummary = try XCTUnwrap(layout.summaries["labelsHidden"])
        let labelledSummary = try XCTUnwrap(layout.summaries["labelled"])

        XCTAssertEqual(row.height, hidden.height, accuracy: 0.5, "RowSwitch makes its row taller than its switch")
        XCTAssertEqual(
            summary.width, hiddenSummary.width, accuracy: 0.5,
            "RowSwitch takes room from the summary it shares a row with"
        )
        XCTAssertLessThan(
            labelledSummary.width, hiddenSummary.width - 1,
            "control: the form no longer stretches a labelled switch, so this test cannot see a stretch"
        )

        let switchReading = try XCTUnwrap(readings["rowSwitch"])
        let hiddenReading = try XCTUnwrap(readings["labelsHidden"])
        XCTAssertEqual(switchReading.minX, hiddenReading.minX, accuracy: 0.5, "RowSwitch moved the row's switch")
    }

    // MARK: - Oracle

    /// Hosts `Harness` in an off-screen window and reads this process's own
    /// accessibility tree, with the harness's layout reported into `layout`
    /// meanwhile. The read runs off the main queue — an AX query aimed at
    /// one's own process is answered on the main runloop, so asking from it
    /// deadlocks — its result comes back through a lock, and the window is
    /// torn down afterwards. On the main actor, where the window and the
    /// harness's layout live.
    @MainActor
    private func hostAndRead(_ layout: Layout = Layout()) throws -> [String: Reading] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: Harness(layout: layout))
        window.orderFront(nil)

        let readings = OSAllocatedUnfairLock<[String: Reading]>(initialState: [:])
        let done = expectation(description: "accessibility read")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            var found: [String: Reading] = [:]
            Self.walk(AXUIElementCreateApplication(getpid()), depth: 0, into: &found)
            let read = found
            readings.withLock { $0 = read }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return readings.withLock { $0 }
    }

    private static func walk(_ element: AXUIElement, depth: Int, into found: inout [String: Reading]) {
        guard depth < 30 else { return }
        let identifier = string(element, "AXIdentifier")
        if !identifier.isEmpty, identifier != "-" {
            found[identifier] = Reading(
                subrole: string(element, kAXSubroleAttribute as String),
                roleDescription: string(element, kAXRoleDescriptionAttribute as String),
                label: string(element, kAXDescriptionAttribute as String),
                minX: position(element).x
            )
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, into: &found) }
    }

    /// `element`'s screen position, or a zero point when it has none.
    private static func position(_ element: AXUIElement) -> CGPoint {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }
}
#endif
