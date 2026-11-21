#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import CabalmailUI

/// What `onSoftwareKeyboardChange(_:)` hands on. A keyboard notification
/// reports its frame in its screen's coordinates, and the fold's crease the
/// frame is compared with is in the window's, so the frame is brought into
/// the window first. A window hosted in the test app's scene away from the
/// screen's origin stands in for one that does not fill its screen, as
/// beside another app in Split View.
///
/// The notifications are posted to a center of the test's own, so the
/// keyboard the app and the system track is never told of them.
@MainActor
final class SoftwareKeyboardFrameTests: XCTestCase {
    private var window: UIWindow?
    /// Where the keyboard ends up, in the test window's coordinates.
    private let inWindow = CGRect(x: 0, y: 200, width: 280, height: 220)

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testAFrameIsBroughtIntoTheWindow() throws {
        let window = try offsetWindow(showing: Color.clear)
        let screen = window.screen
        let onScreen = window.convert(inWindow, to: screen.coordinateSpace)
        XCTAssertNotEqual(onScreen.origin, inWindow.origin, "the two coordinate spaces differ")

        let note = keyboardNote(endFrame: onScreen, screen: screen)
        let frame = try XCTUnwrap(SoftwareKeyboardFrame.end(of: note, in: window))
        assertEqual(frame, inWindow)
    }

    /// With no screen on the notification, or no window to bring the frame
    /// into, the frame is handed on as reported: what every caller got before
    /// the conversion, and right wherever the window fills its screen.
    func testAFrameWithNothingToConvertBetweenComesBackAsReported() throws {
        let window = try offsetWindow(showing: Color.clear)
        let reported = CGRect(x: 0, y: 500, width: 390, height: 344)

        let withoutScreen = keyboardNote(endFrame: reported, screen: nil)
        XCTAssertEqual(SoftwareKeyboardFrame.end(of: withoutScreen, in: window), reported)
        let withScreen = keyboardNote(endFrame: reported, screen: window.screen)
        XCTAssertEqual(SoftwareKeyboardFrame.end(of: withScreen, in: nil), reported)
        let withoutFrame = Notification(name: UIResponder.keyboardWillChangeFrameNotification, object: window.screen)
        XCTAssertNil(SoftwareKeyboardFrame.end(of: withoutFrame, in: window))
    }

    func testTheModifierReportsInItsOwnWindowsCoordinates() async throws {
        let center = NotificationCenter()
        let probe = KeyboardFrameProbe()
        let window = try offsetWindow(
            showing: Color.clear.onSoftwareKeyboardChange(from: center) { probe.frames.append($0) }
        )
        let screen = window.screen
        let note = keyboardNote(endFrame: window.convert(inWindow, to: screen.coordinateSpace), screen: screen)

        // The reader converts once its anchor view is in the window, so the
        // frame is posted until one arrives converted.
        for _ in 0..<300 where !isClose(probe.frames.last ?? nil, inWindow) {
            window.layoutIfNeeded()
            center.post(note)
            try await Task.sleep(for: .milliseconds(10))
        }
        let frame = try XCTUnwrap(probe.frames.last ?? nil, "the modifier never reported a frame")
        assertEqual(frame, inWindow)

        center.post(name: UIResponder.keyboardWillHideNotification, object: screen)
        for _ in 0..<300 where probe.frames.last != .some(nil) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.frames.last, .some(nil), "a hiding keyboard reports no frame")
    }

    /// The fold's crease is read in SwiftUI's `.global` space and the
    /// keyboard's frame is compared with it, so the two have to be one
    /// space: a keyboard that covers exactly this window reports the frame a
    /// view filling the window reads as its own.
    func testAConvertedFrameIsInSwiftUIsGlobalSpace() async throws {
        let center = NotificationCenter()
        let probe = KeyboardFrameProbe()
        let root = Color.clear
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        probe.global = frame
                    }
                    .ignoresSafeArea()
            }
            .onSoftwareKeyboardChange(from: center) { probe.frames.append($0) }
        let window = try offsetWindow(showing: root)
        let screen = window.screen
        let note = keyboardNote(endFrame: window.convert(window.bounds, to: screen.coordinateSpace), screen: screen)

        for _ in 0..<300 where probe.global == nil || !isClose(probe.frames.last ?? nil, window.bounds) {
            window.layoutIfNeeded()
            center.post(note)
            try await Task.sleep(for: .milliseconds(10))
        }
        let global = try XCTUnwrap(probe.global, "the view never read its own frame")
        let frame = try XCTUnwrap(probe.frames.last ?? nil, "the modifier never reported a frame")
        assertEqual(frame, global)
    }

    // MARK: Helpers

    /// A window in the test app's scene whose origin is not its screen's.
    private func offsetWindow(showing root: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test app has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 40, y: 120, width: 280, height: 420)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        window.layoutIfNeeded()
        self.window = window
        let origin = window.convert(CGPoint.zero, to: window.screen.coordinateSpace)
        XCTAssertNotEqual(origin, .zero, "the test window sits at the screen's origin, so nothing is converted")
        return window
    }

    private func keyboardNote(endFrame: CGRect, screen: UIScreen?) -> Notification {
        Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: screen,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: endFrame]
        )
    }

    private func isClose(_ frame: CGRect?, _ expected: CGRect) -> Bool {
        guard let frame else { return false }
        return abs(frame.minX - expected.minX) < 0.01 && abs(frame.minY - expected.minY) < 0.01
            && abs(frame.width - expected.width) < 0.01 && abs(frame.height - expected.height) < 0.01
    }

    private func assertEqual(_ frame: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: 0.01, file: file, line: line)
    }
}

@MainActor
private final class KeyboardFrameProbe {
    /// Every frame the modifier reported, nil for a hide.
    var frames: [CGRect?] = []
    /// A view's own frame in SwiftUI's `.global` space.
    var global: CGRect?
}
#endif
