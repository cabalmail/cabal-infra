#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

/// The composer's formatting buttons take taps over the gap around the
/// 24 pt face they draw (`RichTextToolbar.hitPadding`), so a finger on a
/// touch Mac, an iPhone or an iPad has a 28 x 32 pt target, and nothing on
/// the bar moves to make room. Before, a button took taps on its glyph
/// alone: Bold read 8 x 10 pt here, Heading 1 16 x 15.
///
/// Read through the accessibility API (`HitTargetOracle`): a button's AX
/// frame is its laid-out frame, which its `contentShape` makes its hit area.
/// The face positions are read off the same frames (the padding is
/// symmetric, so a frame's centre is its face's centre), and the bar's
/// height off the hosting view's fitting size.
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

    /// The AX frames of the buttons named `labels`, with the toolbar hosted
    /// in `HitTargetOracle`'s window.
    private func hostAndRead(_ labels: Set<String>) throws -> [String: CGRect] {
        let oracle = try HitTargetOracle(size: NSSize(width: 1000, height: 120)) {
            Harness(controller: RichTextEditorController())
        }
        defer { oracle.close() }
        return oracle.buttonFrames(labels, in: self)
    }
}
#endif
