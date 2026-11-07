#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import CabalmailUI

/// `rowTapAction` stands in for a row-filling `Button` in a `List` row that
/// has swipe actions: on a touch Mac the `Button` kept a finger's swipe from
/// them. What it must keep from the `Button` is checked here, in a `List`
/// row shaped like the address list's (swipe actions both edges, a drag
/// source, a context menu): a click anywhere on the row runs the action,
/// and the row reads as one button that VoiceOver can activate.
///
/// The finger's swipe itself can't be made in-process; it was checked on
/// the MacBook Pro with a build of each variant (docs/1.x/touch-on-mac-plan.md,
/// item 1). `AddressListRowWrapSourceScanTests` pins that the address row
/// uses this modifier.
@MainActor
final class RowTapActionTests: XCTestCase {
    final class Taps { var count = 0 }

    private static let label = "Copy row@a.example"

    private struct Rows: View {
        let tapAction: Bool
        let taps: Taps

        var body: some View {
            List {
                if tapAction {
                    face.rowTapAction(RowTapActionTests.label) { taps.count += 1 }
                        .modifier(RowExtras())
                } else {
                    face.modifier(RowExtras())
                }
            }
            .listStyle(.plain)
        }

        private var face: some View {
            HStack {
                Image(systemName: "at")
                Text("row@a.example")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the address row carries besides its tap.
    private struct RowExtras: ViewModifier {
        func body(content: Content) -> some View {
            content
                .draggable("row@a.example")
                .swipeActions(edge: .leading, allowsFullSwipe: true) { Button("Lead") {} }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button("Trail") {} }
                .contextMenu { Button("Menu") {} }
        }
    }

    private static let size = NSSize(width: 320, height: 120)

    func testAClickAnywhereOnTheRowRunsTheAction() async throws {
        let taps = Taps()
        let oracle = try HitTargetOracle(size: Self.size) { Rows(tapAction: true, taps: taps) }
        defer { oracle.close() }
        let frame = try XCTUnwrap(oracle.buttonFrames([Self.label], in: self)[Self.label], "no row button")

        // On the glyph, then in the blank stretch past the text.
        try await oracle.click(at: CGPoint(x: frame.minX + 14, y: frame.midY))
        XCTAssertEqual(taps.count, 1, "a click on the row's glyph was lost")
        try await oracle.click(at: CGPoint(x: frame.maxX - 10, y: frame.midY))
        XCTAssertEqual(taps.count, 2, "a click past the text was lost: the row's blank stretch takes no tap")
    }

    func testTheRowReadsAsOneButtonSpanningTheRow() throws {
        let oracle = try HitTargetOracle(size: Self.size) { Rows(tapAction: true, taps: Taps()) }
        defer { oracle.close() }
        let frame = try XCTUnwrap(oracle.buttonFrames([Self.label], in: self)[Self.label], "no row button")
        XCTAssertGreaterThan(frame.width, Self.size.width * 0.8, "the button covers the row: \(frame)")
    }

    /// The negative control: the same row without the modifier exposes no
    /// such button, so the test above is reading the modifier, not the List.
    func testWithoutItTheRowIsNoButton() throws {
        let oracle = try HitTargetOracle(size: Self.size) { Rows(tapAction: false, taps: Taps()) }
        defer { oracle.close() }
        XCTAssertNil(oracle.buttonFrames([Self.label], in: self)[Self.label])
    }

    func testAnAccessibilityPressRunsTheAction() throws {
        let taps = Taps()
        let oracle = try HitTargetOracle(size: Self.size) { Rows(tapAction: true, taps: taps) }
        defer { oracle.close() }
        XCTAssertTrue(oracle.press(Self.label, in: self), "no row button to press, or the press was refused")
        let ran = expectation(description: "action")
        Task { @MainActor in
            for _ in 0..<50 where taps.count == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)
        XCTAssertEqual(taps.count, 1, "VoiceOver's activate didn't run the action")
    }
}
#endif
