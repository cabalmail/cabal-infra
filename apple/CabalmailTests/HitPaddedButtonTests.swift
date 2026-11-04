#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

/// `HitPaddedButton` takes clicks beyond its label without its parent laying
/// it out any larger, and the small glyph buttons that use it (the toast's
/// action and close, the unsubscribed-folder banner's refresh, the recipient
/// field's Contacts picker) take taps around their glyph while their rows
/// keep their size.
///
/// Clicks are real mouse events through `HitTargetOracle`. On macOS a
/// `contentShape` larger than the view takes no clicks beyond the frame, so
/// the generic test keeps a plain button beside the padded one as its
/// control: if the plain one starts answering clicks outside its label, the
/// test can no longer tell the padding from the platform.
@MainActor
final class HitPaddedButtonTests: XCTestCase {
    final class Taps { var count = 0 }

    // MARK: - The mechanism

    private struct Square: View {
        let padded: Bool
        let taps: Taps

        var body: some View {
            Group {
                if padded {
                    HitPaddedButton(hitPadding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) {
                        taps.count += 1
                    } label: { face }
                } else {
                    Button { taps.count += 1 } label: { face }
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 200, height: 200)
        }

        /// A 10 pt square centred at (100, 100): its edges are at 95 and 105.
        private var face: some View {
            Rectangle().fill(.gray).frame(width: 10, height: 10)
        }
    }

    func testAClickBeyondTheLabelReachesOnlyThePaddedButton() async throws {
        for padded in [true, false] {
            let taps = Taps()
            let oracle = try HitTargetOracle(size: NSSize(width: 200, height: 200)) {
                Square(padded: padded, taps: taps)
            }
            defer { oracle.close() }
            try await Task.sleep(for: .milliseconds(400))

            try await oracle.click(at: CGPoint(x: 100, y: 100))
            XCTAssertEqual(taps.count, 1, "padded: \(padded): a click on the face itself was lost")
            // 4 pt beyond the face, inside the 8 pt padding.
            try await oracle.click(at: CGPoint(x: 109, y: 100))
            try await oracle.click(at: CGPoint(x: 100, y: 91))
            XCTAssertEqual(taps.count, padded ? 3 : 1, "padded: \(padded)")
            // Beyond the padding: neither answers.
            try await oracle.click(at: CGPoint(x: 116, y: 100))
            XCTAssertEqual(taps.count, padded ? 3 : 1, "padded: \(padded): a click past the padding landed")
        }
    }

    func testTheParentLaysItOutAtTheLabelsSize() {
        let button = HitPaddedButton(hitPadding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12)) {
        } label: {
            Rectangle().frame(width: 10, height: 10)
        }
        .buttonStyle(.borderless)
        let size = NSHostingView(rootView: button).fittingSize
        XCTAssertEqual(size.width, 10, accuracy: 0.5)
        XCTAssertEqual(size.height, 10, accuracy: 0.5)
    }

    // MARK: - The toast

    func testTheToastsButtonsTakeTapsAroundTheirGlyph() async throws {
        let action = Taps()
        let dismiss = Taps()
        let oracle = try HitTargetOracle(size: NSSize(width: 520, height: 90)) {
            BannerView(icon: "checkmark.circle", text: "Address created", tint: .green,
                       onAction: { action.count += 1 }, onDismiss: { dismiss.count += 1 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        defer { oracle.close() }
        let frames = oracle.buttonFrames(["Copy", "Dismiss"], in: self)
        let close = try XCTUnwrap(frames["Dismiss"], "the oracle read no toast buttons")
        let copy = try XCTUnwrap(frames["Copy"])

        // The glyph alone was 10 x 10 (close) and 13 pt tall (action).
        XCTAssertGreaterThanOrEqual(close.width, 30 - 0.5, "close: \(close.size)")
        XCTAssertGreaterThanOrEqual(close.height, 26 - 0.5, "close: \(close.size)")
        XCTAssertGreaterThanOrEqual(copy.height, 29 - 0.5, "action: \(copy.size)")
        XCTAssertLessThanOrEqual(copy.maxX, close.minX, "the action's target reaches over the close button's")

        // A click in each target's far corner, well clear of its glyph.
        try await oracle.click(at: CGPoint(x: close.maxX - 2, y: close.minY + 2))
        XCTAssertEqual(dismiss.count, 1, "a click in the close button's padding was lost")
        try await oracle.click(at: CGPoint(x: copy.minX + 2, y: copy.maxY - 2))
        XCTAssertEqual(action.count, 1, "a click in the action's padding was lost")
        XCTAssertEqual(dismiss.count, 1)
    }

    /// The capsule is as tall as it was: the padding is handed back. Read as
    /// laid out in its window, since a fitting size measures the banner at
    /// its narrowest, where the text wraps and sets the height.
    func testTheToastKeepsItsSize() async throws {
        let measured = Measured()
        let oracle = try HitTargetOracle(size: NSSize(width: 520, height: 90)) {
            BannerView(icon: "checkmark.circle", text: "Address created", tint: .green,
                       onAction: {}, onDismiss: {})
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured.size = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        defer { oracle.close() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(measured.size.height, Self.toastHeight, accuracy: 0.5)
    }

    final class Measured { var size = CGSize.zero }

    // MARK: - The unsubscribed-folder banner

    func testTheUnsubscribedRefreshTakesTapsAroundItsGlyph() async throws {
        let refresh = Taps()
        let oracle = try HitTargetOracle(size: NSSize(width: 520, height: 80)) {
            UnsubscribedBannerRow(isRefreshing: false) { refresh.count += 1 }
        }
        defer { oracle.close() }
        let frames = oracle.buttonFrames(["Refresh folder"], in: self)
        let button = try XCTUnwrap(frames["Refresh folder"], "the oracle read no refresh button")

        // The glyph alone was 12 x 14.
        XCTAssertGreaterThanOrEqual(button.width, 32 - 0.5, "refresh: \(button.size)")
        XCTAssertGreaterThanOrEqual(button.height, 30 - 0.5, "refresh: \(button.size)")
        try await oracle.click(at: CGPoint(x: button.maxX - 2, y: button.maxY - 2))
        XCTAssertEqual(refresh.count, 1, "a click in the refresh button's padding was lost")
    }

    func testTheUnsubscribedBannerKeepsItsSize() {
        let row = UnsubscribedBannerRow(isRefreshing: false) {}.frame(width: 520)
        XCTAssertEqual(NSHostingView(rootView: row).fittingSize.height, Self.unsubscribedHeight, accuracy: 0.5)
    }

    // MARK: - The recipient field

    private struct Recipient: View {
        @FocusState private var focus: Int?
        @State private var text = ""

        var body: some View {
            RecipientFieldWithSuggestions(
                label: "To", text: $text, candidates: [], focusBinding: $focus, focusValue: 0,
                identifier: "compose.to", onContactsAccessChanged: {}
            )
        }
    }

    /// Size only: a click would run the picker, whose first tap asks for
    /// Contacts access, a system prompt on the shared console. The click
    /// path is the same `HitPaddedButton` the tests above drive.
    func testTheContactsPickerTakesTapsAroundItsGlyph() throws {
        let appState = AppState()
        let oracle = try HitTargetOracle(size: NSSize(width: 520, height: 80)) {
            Recipient()
                .environment(appState)
                .environment(Preferences(store: InMemoryPreferenceStore()))
        }
        defer { oracle.close() }
        let frames = oracle.buttonFrames(["compose.to.picker"], in: self)
        let picker = try XCTUnwrap(frames["compose.to.picker"], "the oracle read no picker button")

        // The glyph alone was 21 x 18 here; with its padding it reads 27 x 26
        // (the top-aligned row and the large image scale round it unevenly).
        XCTAssertGreaterThanOrEqual(picker.width, 27 - 0.5, "picker: \(picker.size)")
        XCTAssertGreaterThanOrEqual(picker.height, 24 - 0.5, "picker: \(picker.size)")
    }

    func testTheRecipientFieldKeepsItsSize() {
        let field = Recipient()
            .environment(AppState())
            .environment(Preferences(store: InMemoryPreferenceStore()))
            .frame(width: 520)
        XCTAssertEqual(NSHostingView(rootView: field).fittingSize.height, Self.recipientHeight, accuracy: 0.5)
    }

    // MARK: - Heights before the change

    /// Each container's height as drawn before its button took padding,
    /// measured on macOS 27 with the same frames as the tests above.
    private static let toastHeight: CGFloat = 31
    private static let unsubscribedHeight: CGFloat = 33
    private static let recipientHeight: CGFloat = 24
}
#endif
