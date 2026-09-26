import XCTest
import CabalmailKit
@testable import Cabalmail

/// Issue #1703: a session that lapsed while the app was running left it in a
/// cached mail shell — the list drew "Your session expired. Sign in again."
/// as plain text with no affordance, the reader's `Retry` could not win, and
/// Settings ▸ Account still read "Signed in as claude", because `restore()`
/// was the only code that translated an expiry into a status change. These
/// pin the app half of the fix: the Kit's signal lands on a teardown, and a
/// deliberate sign-out is still distinguishable from one the user did not ask
/// for.
@MainActor
final class SessionExpiryTeardownTests: XCTestCase {
    func testExpirySignalSignsOutWithAReason() async {
        let state = AppState()
        state.status = .signedIn

        await state.handleSessionExpiry()

        XCTAssertEqual(state.status, .signedOut, "the mail shell has to come down")
        XCTAssertEqual(
            state.signedOutReason, .sessionExpired,
            "the sign-in form is where the user learns why they are looking at it"
        )
    }

    /// The report's Settings ▸ Account half: that screen renders `status`,
    /// which was telling the truth about a value nobody updated.
    func testStatusIsNoLongerSignedInAfterAnExpiry() async {
        let state = AppState()
        state.status = .signedIn
        await state.handleSessionExpiry()
        XCTAssertNotEqual(state.status, .signedIn)
    }

    /// A deliberate Sign Out is its own explanation — the form stays blank.
    func testDeliberateSignOutCarriesNoReason() async {
        let state = AppState()
        state.status = .signedIn
        await state.handleSessionExpiry()
        XCTAssertEqual(state.signedOutReason, .sessionExpired, "precondition")

        await state.signOut()

        XCTAssertNil(state.signedOutReason)
        XCTAssertEqual(state.status, .signedOut)
    }

    /// Two requests can die of the same dead session, and the Kit announces
    /// per invalidation — so a second signal must not repaint an explanation
    /// onto a form the user asked for.
    func testASignalAfterSignOutIsANoOp() async {
        let state = AppState()
        state.status = .signedOut
        state.signedOutReason = nil

        await state.handleSessionExpiry()

        XCTAssertNil(state.signedOutReason)
    }

    /// Starting a sign-in clears the explanation: by the time the user is
    /// typing, they have read it.
    func testSubmittingTheFormClearsTheReason() async {
        let state = AppState()
        state.status = .signedIn
        await state.handleSessionExpiry()
        XCTAssertEqual(state.signedOutReason, .sessionExpired, "precondition")

        // No control domain resolves here, so this fails at `ConfigLoader`
        // — after the clear, which is the line under test.
        await state.signIn(
            controlDomain: "cabalmail.invalid",
            username: "alice",
            password: "hunter2"
        )

        XCTAssertNil(state.signedOutReason)
    }
}

/// The sign-in form is the surface the reason exists for, and it has no unit
/// seam — so this scan is what keeps the two ends connected. Reverting the
/// `Section` in `SignInView` fails `testTheFormDrawsTheReason` by name.
final class SignInReasonSourceScanTests: XCTestCase {
    private static let path = "Cabalmail/Views/SignInView.swift"

    func testTheFormDrawsTheReason() throws {
        let code = Self.code(in: try Self.source())
        XCTAssertEqual(
            Self.reasonReadHits(in: code), 1,
            """
            SignInView must branch on appState.signedOutReason, or an expiry \
            drops the user onto a blank form with no explanation (#1703)
            """
        )
        XCTAssertTrue(
            code.contains("Your session expired"),
            "the explanation itself has to be in the form (#1703)"
        )
    }

    /// The copy matches Android's, which fixed the same shape in #1476 — the
    /// two clients should not describe one event differently.
    func testTheCopyMatchesTheAndroidClient() throws {
        let source = try Self.source()
        XCTAssertTrue(
            source.contains("Your session expired — sign in again."),
            "#1476 shipped 'Your session expired — sign in again' on Android"
        )
    }

    /// A comment naming the property is not a use of it.
    func testTheScanReadsCodeNotProse() {
        let reverted = """
        // An expiry used to set appState.signedOutReason == .sessionExpired
        // and this Section drew it.
        Section { Label("Sign in", systemImage: "person") }
        """
        XCTAssertEqual(Self.reasonReadHits(in: Self.code(in: reverted)), 0)
        XCTAssertEqual(
            Self.reasonReadHits(in: "appState.signedOutReason == .sessionExpired // #1703"), 1
        )
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourceIsReadable() throws {
        let source = try Self.source()
        XCTAssertTrue(source.contains("struct SignInView: View"), "\(Self.path) did not load")
    }

    private static func reasonReadHits(in body: String) -> Int {
        let pattern = #"appState\.signedOutReason\s*==\s*\.sessionExpired"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
    }

    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
