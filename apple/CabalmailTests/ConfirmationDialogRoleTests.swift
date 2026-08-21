import XCTest
import SwiftUI
@testable import Cabalmail

// Regression coverage for issue #1201: every `confirmationDialog` in the app
// that still gave its back-out button `role: .cancel` rendered on iPhone as
// an anchored popover showing *only* its destructive button. SwiftUI drops
// the cancel-role button in popover presentation and runs its action on an
// outside tap, so "Revoke <address>?", "Delete Forever?" and "Empty Trash?"
// each offered one labelled control and it was the irreversible one.
//
// #838 reported this for the compose-cancel dialog and #841 fixed it — for
// that one dialog. Eight siblings kept the role: two in `AddressListView`,
// two in `MessageListView`, and one each in `MessageDetailView`,
// `MessageDetailView+AddressMenu`, `FolderListView` and
// `FolderListView+Helpers`. The tester drove the address-revoke one end to
// end on iOS 27 and iOS 26 (same binary, same single-button popover, so this
// is not a 27 delta) and read the other seven off the source.
//
// Two halves are tested here, because the defect had two halves. The rule
// itself is now a policy, which is directly testable. But the rule already
// existed in `ComposeCancelChoice`'s doc comment and eight call sites simply
// did not follow it, so the second half is a source-level invariant: no
// `confirmationDialog` may answer this question on its own.
final class ConfirmationDialogRoleTests: XCTestCase {

    // MARK: - The rule

    func testTouchPlatformsGetNoCancelRole() {
        // Popover presentation would swallow the button outright.
        XCTAssertNil(ConfirmationDialogPolicy.backOutRole(on: .iOS))
        XCTAssertNil(ConfirmationDialogPolicy.backOutRole(on: .visionOS))
    }

    func testMacKeepsTheCancelRoleForEscape() {
        // Alert presentation draws every button and maps Escape onto the
        // cancel-roled one, so dropping it there would cost a real
        // affordance and fix nothing.
        XCTAssertEqual(ConfirmationDialogPolicy.backOutRole(on: .macOS), .cancel)
    }

    /// Without this the suite is vacuous on the compiled-for platform: every
    /// assertion above passes whatever `HostPlatform.current` resolves to, so
    /// a mis-wired `#if` would leave the bug on screen and the tests green.
    /// This host is the one platform that can falsify it (#1167).
    func testCurrentPlatformResolvesOnThisHost() {
        XCTAssertEqual(HostPlatform.current, .macOS)
        XCTAssertEqual(ConfirmationDialogPolicy.backOutRole, .cancel)
    }

    /// The dialog #841 fixed asks the same rule now rather than keeping its
    /// own copy of it — one place to change, which is the point of lifting it.
    func testComposeCancelDialogUsesTheSharedRule() {
        XCTAssertEqual(
            ComposeCancelChoice.keepEditing.role,
            ConfirmationDialogPolicy.backOutRole
        )
    }

    // MARK: - The invariant the call sites broke

    /// No source in the app targets may hardcode `role: .cancel`, outside a
    /// short allowlist of places that are not confirmation dialogs at all.
    ///
    /// This is the half that actually regressed. The rule was written down in
    /// `ComposeCancelChoice`'s doc comment from #841 onwards and eight
    /// dialogs still got it wrong, because nothing connected the two — a
    /// policy nobody is obliged to consult is a comment.
    func testNoDialogHardcodesTheCancelRole() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(
            sources.count, 40,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )

        var offenders: [String: Int] = [:]
        for (name, body) in sources {
            let hits = try Self.cancelRoleHits(in: body)
            if hits > 0 { offenders[name] = hits }
        }

        XCTAssertEqual(
            offenders, Self.allowed,
            "a confirmation dialog must ask ConfirmationDialogPolicy.backOutRole, "
            + "not carry role: .cancel itself (#1201)"
        )
    }

    /// Proves the detector catches the reported shape, on a synthetic snippet
    /// rather than on the corpus — so a legitimate future rewrite of these
    /// views can't quietly make the test above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.cancelRoleHits(in: #"Button("Cancel", role: .cancel) {}"#), 1)
        XCTAssertEqual(try Self.cancelRoleHits(in: #"Button("Cancel", role:   .cancel) { x = nil }"#), 1)
        XCTAssertEqual(
            try Self.cancelRoleHits(in: #"Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}"#),
            0
        )
        XCTAssertEqual(try Self.cancelRoleHits(in: #"Button("Delete", role: .destructive) {}"#), 0)
    }

    // MARK: - Corpus

    /// The two places a literal `.cancel` role is correct and stays.
    ///
    /// - `RichTextToolbar` presents an `.alert`, never a popover, and a
    ///   cancel-role button renders normally there.
    /// - `SignInView`'s pair are ordinary form rows (and a macOS button row),
    ///   not dialog actions.
    ///
    /// `CabalmailWatch` is deliberately outside the scan: watchOS has no
    /// popover presentation for `confirmationDialog`, and its two dialogs are
    /// in a target this policy isn't compiled into.
    private static let allowed = [
        "RichTextToolbar.swift": 1,
        "SignInView.swift": 2,
    ]

    /// `force_try` is on in tests, so this throws rather than asserting the
    /// pattern compiles.
    private static func cancelRoleHits(in body: String) throws -> Int {
        try body.ranges(of: Regex(#"role:\s*\.cancel"#)).count
    }

    /// Every Swift source in the iOS/visionOS and macOS app targets, keyed by
    /// filename. Rooted off this file's own compile-time path so the scan
    /// follows the checkout wherever it lives.
    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["Cabalmail", "CabalmailMac"] {
            let root = apple.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }
}
