#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import ApplicationServices
import os

/// Hosts SwiftUI content in a borderless window and answers the two
/// questions a tap target raises: how big is a button's hit area, and does a
/// click there reach it.
///
/// The frames come from this process's own accessibility tree. A SwiftUI
/// button's AX frame is its laid-out frame, which its `contentShape` makes
/// its hit area. The window sits on screen, because an off-screen hosting
/// view exposes no accessibility tree; nothing is posted globally and the
/// cursor never moves. Clicks are mouse-down/up pairs addressed to this
/// window and handed to `NSApp.sendEvent`, the route `SwipeTestHarness`
/// uses for its scrolls.
@MainActor
final class HitTargetOracle {
    let window: NSWindow
    private let hostingView: NSView

    init<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) throws {
        guard setWindowLocation != nil else {
            throw XCTSkip("CGEventSetWindowLocation is unavailable; cannot address synthetic clicks to a window")
        }
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        hostingView = NSHostingView(rootView: content().frame(width: size.width, height: size.height))
        window.contentView = hostingView
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    /// The frames, in window coordinates with a top-left origin, of the
    /// buttons whose AX description or identifier is in `keys`. The read runs
    /// off the main queue — an AX query aimed at one's own process is
    /// answered on the main runloop, so asking from it deadlocks — and its
    /// result comes back through a lock.
    func buttonFrames(_ keys: Set<String>, in testCase: XCTestCase) -> [String: CGRect] {
        let frames = OSAllocatedUnfairLock<[String: CGRect]>(initialState: [:])
        let done = testCase.expectation(description: "accessibility read")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            var found: [String: CGRect] = [:]
            Self.walk(AXUIElementCreateApplication(getpid()), depth: 0, keys: keys, into: &found)
            let read = found
            frames.withLock { $0 = read }
            done.fulfill()
        }
        testCase.wait(for: [done], timeout: 20)
        // AX reports screen points from the primary screen's top-left; the
        // clicks below want them from the window's.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = CGPoint(x: window.frame.minX, y: screenHeight - window.frame.maxY)
        return frames.withLock { $0 }.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
    }

    /// A left click at `point` (window coordinates, top-left origin).
    func click(at point: CGPoint) async throws {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let setWindowLocation,
                  let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                      mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            // Field 51 is the target window id, as in `SwipeTestHarness`.
            if let windowField = CGEventField(rawValue: 51) {
                event.setIntegerValueField(windowField, value: Int64(window.windowNumber))
            }
            setWindowLocation(event, point)
            if let nsEvent = NSEvent(cgEvent: event) { NSApp.sendEvent(nsEvent) }
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Performs `AXPress`, VoiceOver's activate, on the button whose AX
    /// description or identifier is `key`; false when none was found or the
    /// press was refused. Off the main queue for the reason
    /// `buttonFrames` gives; the action itself runs on the main runloop.
    func press(_ key: String, in testCase: XCTestCase) -> Bool {
        let pressed = OSAllocatedUnfairLock(initialState: false)
        let done = testCase.expectation(description: "accessibility press")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if let button = Self.find(AXUIElementCreateApplication(getpid()), key: key, depth: 0) {
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                pressed.withLock { $0 = result == .success }
            }
            done.fulfill()
        }
        testCase.wait(for: [done], timeout: 20)
        return pressed.withLock { $0 }
    }

    nonisolated private static func find(_ element: AXUIElement, key: String, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if string(element, kAXRoleAttribute as String) == kAXButtonRole as String,
           [string(element, kAXDescriptionAttribute as String), string(element, "AXIdentifier")].contains(key) {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let hit = find(child, key: key, depth: depth + 1) { return hit }
        }
        return nil
    }

    nonisolated private static func walk(
        _ element: AXUIElement, depth: Int, keys: Set<String>, into found: inout [String: CGRect]
    ) {
        guard depth < 30 else { return }
        if string(element, kAXRoleAttribute as String) == kAXButtonRole as String {
            for key in [string(element, kAXDescriptionAttribute as String), string(element, "AXIdentifier")]
            where keys.contains(key) {
                found[key] = frame(element)
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, keys: keys, into: &found) }
    }

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
