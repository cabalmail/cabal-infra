import XCTest
import AppKit
import SwiftUI
@testable import Cabalmail

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
// These drive the real container rather than scanning source: a list of rows
// in an offscreen, borderless window, swiped by phased trackpad-style scroll
// events handed to `NSApp.sendEvent` -- the route AppKit's own input takes, so
// SwiftUI's trackpad swipe adapter sees them -- with no global event posting,
// no cursor movement and nothing on screen. A full swipe runs its edge's
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
        let harness = try await SwipeHarness.make(shape: .swipeActionRow)
        defer { harness.close() }

        try await harness.fullSwipe(row: 1, edge: .trailing)
        XCTAssertEqual(harness.model.fired.last, "trailing row 1 gen 0")

        try await harness.advanceGeneration()
        try await harness.fullSwipe(row: 1, edge: .trailing)
        XCTAssertEqual(
            harness.model.fired.last, "trailing row 1 gen 1",
            "the swipe ran the closure the row had when it was first built (#1747)"
        )

        try await harness.fullSwipe(row: 2, edge: .leading)
        XCTAssertEqual(harness.model.fired.last, "leading row 2 gen 1")
    }

    /// The negative control: 1.22.2's shape, same sequence, must run the stale
    /// closure. If it ever runs the current one, SwiftUI has stopped freezing
    /// swipe content -- the indirection through `LiveSwipeButton` could then be
    /// retired, and the test above proves nothing more than this one would.
    func testHarnessCatchesTheFreezeOnTheSpecButtonShape() async throws {
        let harness = try await SwipeHarness.make(shape: .specButton)
        defer { harness.close() }

        try await harness.fullSwipe(row: 1, edge: .trailing)
        XCTAssertEqual(harness.model.fired.last, "trailing row 1 gen 0")

        try await harness.advanceGeneration()
        try await harness.fullSwipe(row: 1, edge: .trailing)
        if harness.model.fired.last == "trailing row 1 gen 1" {
            throw XCTSkip("""
                SwiftUI no longer freezes .swipeActions content outside a List: \
                LiveSwipeButton's indirection may be unnecessary now (#901)
                """)
        }
        XCTAssertEqual(
            harness.model.fired.last, "trailing row 1 gen 0",
            "the 1.22.2 shape should run its first build's closure; without that this harness can't catch #1747"
        )
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
/// LazyVStack + the gated container -- in a borderless window far offscreen.
@MainActor
private final class SwipeHarness {
    enum Shape {
        /// The shipped row.
        case swipeActionRow
        /// 1.22.2's container row: the spec's own button straight inside
        /// `.swipeActions` -- the shape that froze.
        case specButton
    }

    static let rowHeight: CGFloat = 58
    static let width: CGFloat = 480
    static let rows = 4

    let model = SwipeHarnessModel()
    private let window: NSWindow

    static func make(shape: Shape) async throws -> SwipeHarness {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("the swipe-actions container is macOS 27 and later")
        }
        guard setWindowLocation != nil else {
            throw XCTSkip("CGEventSetWindowLocation is unavailable; cannot address synthetic events to a window")
        }
        let harness = SwipeHarness(shape: shape)
        try await harness.pause(milliseconds: 600)
        return harness
    }

    private init(shape: Shape) {
        let size = NSSize(width: Self.width, height: Self.rowHeight * CGFloat(Self.rows))
        let list = SwipeHarnessList(model: model, shape: shape).frame(width: size.width, height: size.height)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: list)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func advanceGeneration() async throws {
        model.generation += 1
        try await pause(milliseconds: 400)
    }

    /// A long two-finger swipe across `row`: MayBegin, a Began carrying the
    /// first delta (AppKit reads the axis from it), Changed steps well past
    /// the full-swipe threshold, Ended. Negative deltas move the content left,
    /// which reveals the trailing edge. Waits for the action to fire.
    func fullSwipe(row: Int, edge: HorizontalEdge, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = model.fired.count
        let point = CGPoint(x: Self.width / 2, y: (CGFloat(row) + 0.5) * Self.rowHeight)
        let step: Int32 = edge == .trailing ? -24 : 24
        send(at: point, phase: 128, delta: 0)
        try await pause(milliseconds: 16)
        send(at: point, phase: 1, delta: step)
        for _ in 1..<30 {
            try await pause(milliseconds: 16)
            send(at: point, phase: 2, delta: step)
        }
        try await pause(milliseconds: 16)
        send(at: point, phase: 4, delta: 0)

        let deadline = Date().addingTimeInterval(4)
        while model.fired.count == before, Date() < deadline {
            try await pause(milliseconds: 25)
        }
        XCTAssertGreaterThan(
            model.fired.count, before,
            "a full swipe on row \(row) ran no action; the harness isn't reaching the swipe", file: file, line: line
        )
        // Let the row settle closed before the next swipe.
        try await pause(milliseconds: 700)
    }

    /// One phased, continuous (trackpad) horizontal scroll event addressed to
    /// this window at `point` (window coordinates, top-left origin).
    private func send(at point: CGPoint, phase: Int64, delta: Int32) {
        guard let setWindowLocation,
              let event = CGEvent(
                  scrollWheelEvent2Source: nil, units: .pixel,
                  wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0
              ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(delta))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(delta))
        // Field 51 is the target window id -- the field AppKit reads for
        // NSEvent.windowNumber -- and the window-relative point is set through
        // the private CoreGraphics call below. Test harness only.
        if let windowField = CGEventField(rawValue: 51) {
            event.setIntegerValueField(windowField, value: Int64(window.windowNumber))
        }
        setWindowLocation(event, point)
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        NSApp.sendEvent(nsEvent)
    }

    private func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void

/// `CGEventSetWindowLocation`, looked up at run time: the only way to give a
/// synthetic scroll event a window-relative location, which is what lets the
/// harness address an offscreen window without posting anything globally.
private let setWindowLocation: SetWindowLocation? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
    return unsafeBitCast(symbol, to: SetWindowLocation.self)
}()

private struct SwipeHarnessList: View {
    let model: SwipeHarnessModel
    let shape: SwipeHarness.Shape

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<SwipeHarness.rows, id: \.self) { index in
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
                height: SwipeHarness.rowHeight, rowBackground: .clear,
                leading: leading, trailing: trailing,
                onSelect: {}, content: { label }
            )
        case .specButton:
            Button(action: {}, label: {
                label
                    .frame(maxWidth: .infinity, minHeight: SwipeHarness.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: SwipeHarness.rowHeight)
            .clipped()
            .swipeActions(edge: .trailing) { trailing.revealedButton }
            .swipeActions(edge: .leading) { leading.revealedButton }
        }
    }
}
