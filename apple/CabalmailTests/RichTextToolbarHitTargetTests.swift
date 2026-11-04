#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import ApplicationServices
import os
import CabalmailKit
@testable import CabalmailUI

/// The composer's formatting buttons take taps over the gap around the
/// 24 pt face they draw (`RichTextToolbar.hitPadding`), so a finger on a
/// touch Mac, an iPhone or an iPad has a 28 x 32 pt target, and nothing on
/// the bar moves to make room. Before, a button took taps on its glyph
/// alone: Bold read 8 x 10 pt here, Heading 1 16 x 15.
///
/// Read through the accessibility API: a button's AX frame is its laid-out
/// frame, which its `contentShape` makes its hit area. The face positions
/// are read off the same frames (the padding is symmetric, so a frame's
/// centre is its face's centre), and the bar's height off the hosting
/// view's fitting size.
@MainActor
final class RichTextToolbarHitTargetTests: XCTestCase {

    private struct Harness: View {
        let controller: RichTextEditorController

        var body: some View {
            RichTextToolbar(controller: controller, selection: .init(), onImportFromMarkdown: {})
                .frame(width: 1000, alignment: .leading)
        }
    }

    func testButtonsTakeTapsOverTheGapAroundTheirFace() throws {
        let frames = try hostAndRead(["Bold", "Italic", "Heading 1"])
        let bold = try XCTUnwrap(frames["Bold"], "the oracle read no toolbar buttons")
        let heading = try XCTUnwrap(frames["Heading 1"])

        XCTAssertGreaterThanOrEqual(bold.width, 28 - 0.5, "Bold's target is \(bold.size)")
        XCTAssertGreaterThanOrEqual(bold.height, 32 - 0.5, "Bold's target is \(bold.size)")
        XCTAssertGreaterThanOrEqual(heading.width, 30 - 0.5, "Heading 1's target is \(heading.size)")
        XCTAssertGreaterThanOrEqual(heading.height, 32 - 0.5, "Heading 1's target is \(heading.size)")
    }

    /// Neighbours share an edge rather than overlap, so a tap between two
    /// faces still lands on exactly one button.
    func testNeighbouringTargetsDoNotOverlap() throws {
        let frames = try hostAndRead(["Bold", "Italic"])
        let bold = try XCTUnwrap(frames["Bold"])
        let italic = try XCTUnwrap(frames["Italic"])
        XCTAssertLessThanOrEqual(bold.maxX, italic.minX + 0.5, "Bold \(bold) overlaps Italic \(italic)")
    }

    /// The faces keep the spacing they had when the bar spaced them itself:
    /// 24 pt faces 4 pt apart (a 28 pt pitch), and 13 pt across a divider.
    func testFacesKeepTheirSpacing() throws {
        let frames = try hostAndRead(["Bold", "Italic", "Strikethrough", "Heading 1"])
        let bold = try XCTUnwrap(frames["Bold"])
        let italic = try XCTUnwrap(frames["Italic"])
        let strikethrough = try XCTUnwrap(frames["Strikethrough"])
        let heading = try XCTUnwrap(frames["Heading 1"])

        XCTAssertEqual(italic.midX - bold.midX, 28, accuracy: 0.5)
        // Half a 24 pt face, the 13 pt group gap, half a 26 pt heading face.
        XCTAssertEqual(heading.midX - strikethrough.midX, 12 + 13 + 13, accuracy: 0.5)
        XCTAssertEqual(bold.midY, italic.midY, accuracy: 0.5)
    }

    /// The bar is as tall as it was: a 24 pt face and 4 pt above and below.
    func testTheBarKeepsItsHeight() {
        let view = NSHostingView(rootView: Harness(controller: RichTextEditorController()))
        XCTAssertEqual(view.fittingSize.height, 32, accuracy: 0.5)
    }

    // MARK: - Oracle

    /// Hosts the toolbar in an off-screen window and reads the AX frames of
    /// the buttons named `labels` from this process's own accessibility
    /// tree. As in `RowSwitchAccessibilityTests`, the read runs off the main
    /// queue: an AX query aimed at one's own process is answered on the main
    /// runloop, so asking from it deadlocks.
    private func hostAndRead(_ labels: Set<String>) throws -> [String: CGRect] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: Harness(controller: RichTextEditorController()))
        window.orderFront(nil)

        // The read's result crosses back from the global queue through a
        // lock: a captured `var` written there is a data race to the compiler.
        let frames = OSAllocatedUnfairLock<[String: CGRect]>(initialState: [:])
        let done = expectation(description: "accessibility read")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            var found: [String: CGRect] = [:]
            Self.walk(AXUIElementCreateApplication(getpid()), depth: 0, labels: labels, into: &found)
            let read = found
            frames.withLock { $0 = read }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return frames.withLock { $0 }
    }

    nonisolated private static func walk(
        _ element: AXUIElement, depth: Int, labels: Set<String>, into found: inout [String: CGRect]
    ) {
        guard depth < 25 else { return }
        if string(element, kAXRoleAttribute as String) == kAXButtonRole as String {
            let label = string(element, kAXDescriptionAttribute as String)
            if labels.contains(label) { found[label] = frame(element) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, labels: labels, into: &found) }
    }

    /// `element`'s screen frame, or `.null` when it has none.
    nonisolated private static func frame(_ element: AXUIElement) -> CGRect {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute)
        else { return .null }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent)
        else { return .null }
        return CGRect(origin: origin, size: extent)
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXValue)
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }
}
#endif
