import XCTest
import AppKit
import SwiftUI

/// Hosts SwiftUI content in an offscreen, borderless window and swipes it the
/// way a trackpad does: phased, continuous horizontal scroll events handed to
/// `NSApp.sendEvent` -- the route AppKit's own input takes, so SwiftUI's
/// trackpad swipe adapter sees them (`NSWindow.sendEvent` does not reach it).
/// Nothing is posted globally, the cursor never moves and nothing appears on
/// screen, so these tests can run beside anything else using the display.
///
/// A full swipe runs its edge's first action without a click, so tests
/// observe outcomes through the action closures; the offscreen hosting view
/// exposes no accessibility tree to read revealed buttons from.
@MainActor
final class SwipeTestHarness {
    static let rowHeight: CGFloat = 58
    static let width: CGFloat = 480

    private let window: NSWindow

    /// A harness around `content`, `rows` rows tall -- or a skip where the
    /// swipe-actions container (macOS 27 and later) or the event addressing
    /// isn't available.
    static func make<Content: View>(
        rows: Int,
        @ViewBuilder content: () -> Content
    ) async throws -> SwipeTestHarness {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("the swipe-actions container is macOS 27 and later")
        }
        guard setWindowLocation != nil else {
            throw XCTSkip("CGEventSetWindowLocation is unavailable; cannot address synthetic events to a window")
        }
        let harness = SwipeTestHarness(rows: rows, content: content())
        try await harness.pause(milliseconds: 600)
        return harness
    }

    private init<Content: View>(rows: Int, content: Content) {
        let size = NSSize(width: Self.width, height: Self.rowHeight * CGFloat(rows))
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    /// A long two-finger swipe across the row drawn at `row` (counted in row
    /// heights from the top): MayBegin, a Began carrying the first delta
    /// (AppKit reads the axis from it), Changed steps well past the
    /// full-swipe threshold, Ended. Negative deltas move the content left,
    /// which reveals the trailing edge. Returns once Ended has gone out; the
    /// caller waits for whatever the swipe should (or shouldn't) do.
    func sendFullSwipe(row: Int, edge: HorizontalEdge) async throws {
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
    }

    /// Waits until `condition` holds or `timeout` passes, and says which.
    func eventually(within timeout: Duration = .seconds(4), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await pause(milliseconds: 25)
        }
        return true
    }

    func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
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
}

private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void

/// `CGEventSetWindowLocation`, looked up at run time: the only way to give a
/// synthetic scroll event a window-relative location, which is what lets the
/// harness address an offscreen window without posting anything globally.
private let setWindowLocation: SetWindowLocation? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
    return unsafeBitCast(symbol, to: SetWindowLocation.self)
}()
