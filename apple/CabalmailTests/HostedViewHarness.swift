import XCTest
import AppKit
import SwiftUI

/// Hosts SwiftUI content in an offscreen, borderless window, so its
/// `onAppear`, `onChange` and `onDisappear` run as they do on screen: the
/// window setup `SwipeTestHarness` uses, without its swipe events. Nothing
/// appears on screen and nothing is posted, so these tests can run beside
/// anything else using the display.
@MainActor
final class HostedViewHarness {
    private let window: NSWindow

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let size = NSSize(width: 320, height: 240)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content().frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    /// Lets SwiftUI run its pending updates.
    func settle(milliseconds: Int = 300) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Waits until `condition` holds or `timeout` passes, and says which.
    func eventually(within timeout: Duration = .seconds(4), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(25))
        }
        return true
    }
}
