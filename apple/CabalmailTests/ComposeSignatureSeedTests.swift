import XCTest
import CabalmailKit
@testable import Cabalmail

/// Regression coverage for issue #1132: with a signature configured, every
/// new message the user opened and abandoned raised the "Discard draft?"
/// dialog — the one #1099 / #1118 set out to remove for untouched composers.
///
/// Not a regression of that fix. `ComposeViewModel.init` seeds the Markdown
/// pane via `SignatureFormatter.seedBody`, so a brand-new composer really
/// does hold body text before the user touches anything, and
/// `hasDraftContent(bodies:)` — an emptiness test — was right to say so. The
/// rule was asking the wrong question: what matters is whether the *user*
/// put anything there.
///
/// The narrowness is the whole risk. A reply's quoted original and a
/// resumed draft's fetched body are seeds too, and treating either as
/// "nothing to keep" would resolve to `.discardEmpty`, which drops the
/// server copy. Those cases are pinned below.
@MainActor
final class ComposeSignatureSeedTests: XCTestCase {

    private static let signature = "Sent from Android"

    /// What `SignatureFormatter` puts in the Markdown pane for a new message.
    private static var signatureSeed: String {
        SignatureFormatter.seedBody(base: "", signature: signature)
    }

    /// Stands in for what `computeMessageBodies()` returns for a `.markdown`
    /// source: the Markdown buffer verbatim plus its rendered HTML.
    private static func renderedBodies(_ markdown: String) -> ComposeBodies {
        ComposeBodies(
            text: markdown,
            html: "<p><br></p><p>-- <br>\(signature)</p>",
            source: .markdown
        )
    }

    // MARK: - The reported flow

    /// New Message, touch nothing, close. The seeded signature is the only
    /// thing in the buffer, so there is nothing to ask about.
    func testUntouchedSignatureSeedIsNotContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)

        XCTAssertEqual(model.markdownBody, Self.signatureSeed, "precondition: init seeded the pane")
        XCTAssertFalse(model.hasDraftContent(bodies: Self.renderedBodies(model.markdownBody)))
        XCTAssertFalse(
            ComposeCancelPolicy.needsDecision(bridgeFailed: false, hasContent: false),
            "and therefore no dialog"
        )
    }

    /// The verifier's positive control, at this layer: the same composer
    /// with a subject typed is content, so the dialog comes back. Without
    /// this the test above would pass against a detector that never fires.
    func testTypedSubjectOverASignatureIsStillContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        model.subject = "t1132 probe"

        XCTAssertTrue(model.hasDraftContent(bodies: Self.renderedBodies(model.markdownBody)))
    }

    /// Typing in the Markdown pane moves it off the seed.
    func testTypingOverTheSignatureIsContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        model.markdownBody = "actual words\n" + Self.signatureSeed

        XCTAssertTrue(model.hasDraftContent(bodies: Self.renderedBodies(model.markdownBody)))
    }

    /// Typing in the *rich* pane clears the mirror flag without touching the
    /// Markdown buffer, so the seed comparison alone would miss it.
    func testTypingInTheRichPaneIsContentEvenWithTheSeedIntact() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        model.richMirrorsMarkdown = false

        XCTAssertEqual(model.markdownBody, Self.signatureSeed, "precondition: Markdown pane untouched")
        XCTAssertTrue(
            model.hasDraftContent(
                bodies: ComposeBodies(text: "typed richly", html: "<p>typed richly</p>", source: .rich)
            )
        )
    }

    // MARK: - Seeds that must keep counting as content

    /// A resumed draft seeds the pane from its fetched `text/plain` part.
    /// Opening one and closing it must not resolve to `.discardEmpty` — that
    /// would expunge the server copy the user came back for.
    func testResumedDraftBodyWithASignatureStaysContent() throws {
        let seed = Draft(body: "the draft I saved yesterday")
        let model = try TestFixtures.makeComposeModel(seed: seed, signature: Self.signature)

        XCTAssertNotEqual(model.markdownBody, Self.signatureSeed)
        XCTAssertTrue(model.hasDraftContent(bodies: Self.renderedBodies(model.markdownBody)))
    }

    /// Same for a reply's attribution + quoted original.
    func testReplyQuotedBodyWithASignatureStaysContent() throws {
        let seed = Draft(body: "\n\nOn Tuesday, someone wrote:\n\n> the original")
        let model = try TestFixtures.makeComposeModel(seed: seed, signature: Self.signature)

        XCTAssertTrue(model.hasDraftContent(bodies: Self.renderedBodies(model.markdownBody)))
    }

    /// Accounts with no signature behave exactly as they did before: the
    /// pane starts genuinely empty and the bodies convert to "".
    func testNoSignatureIsUnchanged() throws {
        let model = try TestFixtures.makeComposeModel()

        XCTAssertEqual(model.markdownBody, "")
        XCTAssertFalse(model.hasDraftContent(bodies: ComposeBodies(text: "", html: "", source: .empty)))
        XCTAssertTrue(
            model.hasDraftContent(
                bodies: ComposeBodies(text: "typed", html: "<p>typed</p>", source: .rich)
            )
        )
    }

    // MARK: - The pure rule

    func testPolicyRecognizesTheUntouchedSeed() {
        XCTAssertTrue(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: Self.signatureSeed,
                richPaneAuthored: false,
                signatureOnlySeed: Self.signatureSeed
            )
        )
    }

    func testPolicyRejectsATouchedPane() {
        XCTAssertFalse(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: Self.signatureSeed,
                richPaneAuthored: true,
                signatureOnlySeed: Self.signatureSeed
            ),
            "the rich pane was typed in"
        )
        XCTAssertFalse(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: "words\n" + Self.signatureSeed,
                richPaneAuthored: false,
                signatureOnlySeed: Self.signatureSeed
            ),
            "the markdown pane was typed in"
        )
    }

    /// With no signature there is no seed to match, so the rule never fires
    /// and an empty `markdownBody` is not mistaken for one.
    func testPolicyNeverFiresWithoutASignature() {
        XCTAssertFalse(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: "",
                richPaneAuthored: false,
                signatureOnlySeed: ""
            )
        )
    }

    /// `importFromRichText` re-seeds the Markdown pane with the user's own
    /// copy and sets the mirror flag back to `true`. Comparing against the
    /// signature seed rather than a "was it edited" flag is what keeps that
    /// body counting as content.
    func testImportedRichTextIsNotMistakenForTheSeed() {
        XCTAssertFalse(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: "words the user wrote in the rich pane",
                richPaneAuthored: false,
                signatureOnlySeed: Self.signatureSeed
            )
        )
    }
}
