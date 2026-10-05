import XCTest
import AppKit
import SwiftUI
@testable import CabalmailUI

// Regression coverage for the finding behind the 1.22.3 revert (#901, #1747).
//
// Outside a `List`, SwiftUI 27 keeps each row's `.swipeActions` content from the
// row's first build: the row publishes its actions as a preference that a
// per-row host copies into state, and the equality gating that copy compares
// only the edge, `allowsFullSwipe` and which edges exist -- never the actions.
// 1.22.2 handed `.swipeActions` a `Button` built from the row's
// `SwipeActionSpec`, so every swipe ran the closure (and showed the caption)
// the row had when it was first drawn. With index-addressed rows that closure
// held whichever message first occupied the slot: read/unread stuck, macOS
// actions no-opped, and after a list shift a swipe could act on another
// message. `SwipeActionRow` now hands `.swipeActions` a `LiveSwipeButton` that
// stores only its edge and reads the row's current spec from the environment.
//
// These drive the real container rather than scanning source, through
// `SwipeTestHarness`: a list of rows in an offscreen window, swiped by
// trackpad-style scroll events sent in-process. A full swipe runs its edge's
// action without a click, so each test reads which closure ran instead of
// scraping the revealed button. The negative control runs the same sequence on
// 1.22.2's shape and must see the stale closure; that is what shows the
// harness can catch the regression at all.
@MainActor
final class SwipeActionLiveContentTests: XCTestCase {

    /// The shape half of the contract, and the one check that runs below 27:
    /// SwiftUI keeps `LiveSwipeButton` from the first build, so any stored
    /// property besides its edge would be frozen with it.
    func testLiveSwipeButtonStoresNothingButItsEdge() {
        let labels = Mirror(reflecting: LiveSwipeButton(edge: .leading)).children.compactMap(\.label)
        XCTAssertEqual(
            labels.sorted(), ["_specs", "edge"],
            "LiveSwipeButton must read row data from the environment, never store it (#1747)"
        )
    }

    /// The fix: after the row's data changes, a full swipe on the SAME row runs
    /// the new spec's closure, on both edges.
    func testFullSwipeRunsTheRowsCurrentSpecAfterItsDataChanges() async throws {
        let model = SwipeHarnessModel()
        let harness = try await SwipeTestHarness.make(rows: SwipeHarnessList.rows) {
            SwipeHarnessList(model: model, shape: .swipeActionRow)
        }
        defer { harness.close() }

        try await fullSwipe(harness, model, row: 1, edge: .trailing)
        XCTAssertEqual(model.fired.last, "trailing row 1 gen 0")

        try await advanceGeneration(harness, model)
        try await fullSwipe(harness, model, row: 1, edge: .trailing)
        XCTAssertEqual(
            model.fired.last, "trailing row 1 gen 1",
            "the swipe ran the closure the row had when it was first built (#1747)"
        )

        try await fullSwipe(harness, model, row: 2, edge: .leading)
        XCTAssertEqual(model.fired.last, "leading row 2 gen 1")
    }

    /// The negative control: 1.22.2's shape, same sequence, must run the stale
    /// closure. If it ever runs the current one, SwiftUI has stopped freezing
    /// swipe content -- the indirection through `LiveSwipeButton` could then be
    /// retired, and the test above proves nothing more than this one would.
    func testHarnessCatchesTheFreezeOnTheSpecButtonShape() async throws {
        let model = SwipeHarnessModel()
        let harness = try await SwipeTestHarness.make(rows: SwipeHarnessList.rows) {
            SwipeHarnessList(model: model, shape: .specButton)
        }
        defer { harness.close() }

        try await fullSwipe(harness, model, row: 1, edge: .trailing)
        XCTAssertEqual(model.fired.last, "trailing row 1 gen 0")

        try await advanceGeneration(harness, model)
        try await fullSwipe(harness, model, row: 1, edge: .trailing)
        if model.fired.last == "trailing row 1 gen 1" {
            throw XCTSkip("""
                SwiftUI no longer freezes .swipeActions content outside a List: \
                LiveSwipeButton's indirection may be unnecessary now (#901)
                """)
        }
        XCTAssertEqual(
            model.fired.last, "trailing row 1 gen 0",
            "the 1.22.2 shape should run its first build's closure; without that this harness can't catch #1747"
        )
    }

    /// A full swipe that must run an action, then time for the row to settle
    /// closed before the next one.
    private func fullSwipe(
        _ harness: SwipeTestHarness, _ model: SwipeHarnessModel,
        row: Int, edge: HorizontalEdge,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = model.fired.count
        try await harness.sendFullSwipe(row: row, edge: edge)
        let fired = try await harness.eventually { model.fired.count > before }
        XCTAssertTrue(
            fired, "a full swipe on row \(row) ran no action; the harness isn't reaching the swipe",
            file: file, line: line
        )
        try await harness.pause(milliseconds: 700)
    }

    private func advanceGeneration(_ harness: SwipeTestHarness, _ model: SwipeHarnessModel) async throws {
        model.generation += 1
        try await harness.pause(milliseconds: 400)
    }
}

/// What the swiped rows report. `generation` stands in for the row data a
/// refresh or a list shift changes under a row whose identity stays the same
/// -- the index-addressed list's normal case.
@Observable
private final class SwipeHarnessModel {
    var generation = 0
    var fired: [String] = []
}

/// Four fixed-height rows in the message list's shape -- ScrollView +
/// LazyVStack + the gated container.
private struct SwipeHarnessList: View {
    enum Shape {
        /// The shipped row.
        case swipeActionRow
        /// 1.22.2's container row: the spec's own button straight inside
        /// `.swipeActions` -- the shape that froze.
        case specButton
    }

    static let rows = 4

    let model: SwipeHarnessModel
    let shape: Shape

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<Self.rows, id: \.self) { index in
                    row(index)
                }
            }
        }
        .coordinatedSwipeActionsContainer()
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let generation = model.generation
        let leading = SwipeActionSpec(systemImage: "envelope.open", title: "Read \(generation)", tint: .blue) {
            model.fired.append("leading row \(index) gen \(generation)")
        }
        let trailing = SwipeActionSpec(systemImage: "archivebox", title: "Archive \(generation)", tint: .red) {
            model.fired.append("trailing row \(index) gen \(generation)")
        }
        let label = Text("Row \(index), generation \(generation)")
        switch shape {
        case .swipeActionRow:
            SwipeActionRow(
                height: SwipeTestHarness.rowHeight, contentID: index, rowBackground: .clear,
                leading: leading, trailing: trailing,
                onSelect: {}, content: { label }
            )
        case .specButton:
            Button(action: {}, label: {
                label
                    .frame(maxWidth: .infinity, minHeight: SwipeTestHarness.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: SwipeTestHarness.rowHeight)
            .clipped()
            .swipeActions(edge: .trailing) { trailing.revealedButton }
            .swipeActions(edge: .leading) { leading.revealedButton }
        }
    }
}
