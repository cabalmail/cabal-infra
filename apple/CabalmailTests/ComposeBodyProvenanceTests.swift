import XCTest
import CabalmailKit
@testable import Cabalmail

/// Regression coverage for issue #1091: a message that went out carrying two
/// different bodies.
///
/// The send-time table read "the Markdown buffer is non-empty" as "the user
/// typed in the Markdown pane". That is false for every composer the app
/// seeds — a resumed draft (seeded from the fetched `text/plain` part), a
/// reply (quoted original), and, as the verification pass measured, *any*
/// compose belonging to a user with a signature preference set. Editing such
/// a composer in the Rich Text pane shipped the untouched seed as the
/// `text/plain` part and the edit as the `text/html` part, so a plain-text
/// recipient read text the sender never wrote — and, because resume prefers
/// the text part, the next Edit Draft reopened the pre-edit body.
final class ComposeBodyProvenanceTests: XCTestCase {

    // MARK: - The reported flow: resumed draft, edited in the rich pane

    /// Resume a draft (`markdownBody` seeded from its text part), append in
    /// the Rich Text pane, save. The rich pane is the only authored surface,
    /// so the text part has to be derived from it rather than taken from the
    /// seed.
    func testRichEditOverAResumedSeedShipsOneBody() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>ALPHA BETA</p>",
            richMirrorsMarkdown: false,
            markdownBody: "ALPHA",
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .rich)
    }

    /// The verifier's corrected scope: no draft involved. A signature
    /// preference seeds `markdownBody` on every fresh compose, so the first
    /// rich-pane keystroke used to land in the same branch — and shipped the
    /// signature *alone* as the text part, losing the whole typed body.
    func testRichEditOverASignatureSeedShipsOneBody() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>DELTA1091<br>-- <br>SIG1091</p>",
            richMirrorsMarkdown: false,
            markdownBody: "\n-- \nSIG1091",
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .rich)
    }

    // MARK: - What must not change

    /// Two genuinely authored panes still ship as written — that is the
    /// dual-mode composer working as designed, not the defect.
    func testBothPanesAuthoredStillShipAsWritten() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>hand-written html</p>",
            richMirrorsMarkdown: false,
            markdownBody: "hand-written markdown",
            markdownUserEdited: true
        )

        XCTAssertEqual(source, .both)
    }

    /// Resume a draft and change only the subject. The seed is untouched and
    /// the rich pane still mirrors it, so the body must be re-rendered from
    /// the Markdown source — dropping it here would silently blank the draft.
    func testUntouchedResumedDraftKeepsItsSeededBody() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>ALPHA</p>",
            richMirrorsMarkdown: true,
            markdownBody: "ALPHA",
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .markdown)
    }

    /// Typing in the Markdown pane of a signature-seeded compose: still a
    /// Markdown compose, and the rich pane is a mirror.
    func testMarkdownOnlyComposeIsUnaffected() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>typed in markdown</p>",
            richMirrorsMarkdown: true,
            markdownBody: "typed in markdown",
            markdownUserEdited: true
        )

        XCTAssertEqual(source, .markdown)
    }

    /// A fresh compose with no signature, typed in the rich pane — the path
    /// that always worked, and the control the verification pass measured.
    func testFreshRichComposeDerivesItsTextPart() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p>ALPHA1091</p>",
            richMirrorsMarkdown: false,
            markdownBody: "",
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .rich)
    }

    func testEmptyComposeShipsNothing() {
        XCTAssertEqual(
            ComposeBodyPolicy.source(
                richHTML: "",
                richMirrorsMarkdown: true,
                markdownBody: "   \n ",
                markdownUserEdited: false
            ),
            .empty
        )
    }

    // MARK: - Where the view model's answer comes from

    /// The flag is provenance, not emptiness: a seeded buffer the user has
    /// not touched reads as un-authored however full it is.
    @MainActor
    func testSeededBodyDoesNotCountAsUserEdited() throws {
        let model = try TestFixtures.makeComposeModel(seed: Draft(subject: "s", body: "ALPHA"))

        XCTAssertFalse(model.markdownBody.isEmpty)
        XCTAssertFalse(model.markdownUserEdited)
    }

    @MainActor
    func testSignatureSeedDoesNotCountAsUserEdited() throws {
        let model = try TestFixtures.makeComposeModel(signature: "SIG1091 tester signature")

        XCTAssertTrue(model.markdownBody.contains("SIG1091"))
        XCTAssertFalse(model.markdownUserEdited)
    }

    /// The markdown `TextEditor` is the only other writer of the buffer, so
    /// a change to it is the user typing.
    @MainActor
    func testTypingInTheMarkdownPaneCountsAsUserEdited() throws {
        let model = try TestFixtures.makeComposeModel(seed: Draft(subject: "s", body: "ALPHA"))

        model.markdownBody += " typed by hand"

        XCTAssertTrue(model.markdownUserEdited)
    }
}
