import XCTest
import CabalmailKit
@testable import Cabalmail

/// Regression coverage for issue #1138: with a signature configured, typing
/// into the Rich Text pane and then deleting it all left the composer
/// permanently "dirty" — `Cancel` kept raising the "Discard draft?" sheet
/// over a composer with nothing in any field, and the 60 s server autosave
/// kept writing a draft whose body was the signature and nothing else.
///
/// Two independent causes, one per layer, and neither alone produced the
/// symptom on both platforms the verifier drove:
///
/// 1. `editor-bridge.js`'s `isEmpty()` matched `''`, `'<p></p>'` and
///    `'<br>'` — but select-all + delete over a document that had
///    paragraphs leaves `<p><br></p>`, which it missed. `getHTML()` then
///    handed back 12 characters of scaffolding as if the user had written
///    them. Pinned in `RichTextEditorControllerTests` against a live
///    WebKit bridge, because it is a fact about WebKit, not about Swift.
/// 2. `bodyIsUntouchedSignature` required `richMirrorsMarkdown`, i.e. that
///    the user had never touched the rich pane. Once the pane read empty
///    (case 1 fixed, or a platform that empties it outright) the composer
///    was back to holding only the seeded signature, but the flag still
///    recorded the first keystroke and the seed still counted as content.
///
/// Fixing only the first leaves the second: an empty rich pane over a
/// signature seed resolves to `.markdown`, whose parts are the *seed*, so
/// the parts alone can never answer "is the rich pane empty". That is why
/// `ComposeBodies` carries the `source` decision.
///
/// The risk here is the same one #1132 carried: a reply's quoted original
/// and a resumed draft's fetched body are seeds too, and calling either
/// "nothing to keep" resolves to `.discardEmpty`, which expunges the server
/// copy. Both are pinned below with the rich pane emptied, the exact shape
/// the widened rule could have swallowed.
@MainActor
final class ComposeClearedBodyTests: XCTestCase {

    private static let signature = "Sent from Android"

    private static var signatureSeed: String {
        SignatureFormatter.seedBody(base: "", signature: signature)
    }

    /// What `computeMessageBodies()` returns once the rich pane reads empty:
    /// the source falls through to `.markdown`, so the parts are the seed
    /// rendered out — non-empty HTML over an editor showing its placeholder.
    private static func bodiesForEmptiedRichPane(_ markdown: String) -> ComposeBodies {
        ComposeBodies(
            text: markdown,
            html: "<p><br></p><p>-- <br>\(signature)</p>",
            source: .markdown
        )
    }

    // MARK: - The reported flow

    /// Type in the rich pane, delete it all, Cancel. Every field is empty
    /// and the Markdown pane still holds only the signature the composer
    /// seeded, so there is nothing to ask about.
    func testEmptiedRichPaneOverASignatureIsNotContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        // The user typed at some point — that is what used to be fatal.
        model.richMirrorsMarkdown = false

        XCTAssertEqual(model.markdownBody, Self.signatureSeed, "precondition: Markdown pane untouched")
        XCTAssertFalse(model.hasDraftContent(bodies: Self.bodiesForEmptiedRichPane(model.markdownBody)))
        XCTAssertFalse(
            ComposeCancelPolicy.needsDecision(bridgeFailed: false, hasContent: false),
            "and therefore no dialog"
        )
    }

    /// Positive control at the same layer: the identical composer with a
    /// subject typed is content, so the dialog comes back. Without this the
    /// test above would pass against a detector that never fires.
    func testTypedSubjectOverAnEmptiedRichPaneIsStillContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        model.richMirrorsMarkdown = false
        model.subject = "t1138 probe"

        XCTAssertTrue(model.hasDraftContent(bodies: Self.bodiesForEmptiedRichPane(model.markdownBody)))
    }

    /// The rich pane still holding copy is untouched by this: `.rich` says
    /// the pane is the surface with the user's words in it.
    func testRichPaneWithCopyIsStillContent() throws {
        let model = try TestFixtures.makeComposeModel(signature: Self.signature)
        model.richMirrorsMarkdown = false

        XCTAssertTrue(
            model.hasDraftContent(
                bodies: ComposeBodies(text: "typed richly", html: "<p>typed richly</p>", source: .rich)
            )
        )
    }

    // MARK: - Seeds that must keep counting as content

    /// A resumed draft whose rich pane the user cleared. The Markdown pane
    /// still holds the fetched body, which is not the signature seed, so
    /// this is content and Cancel must keep asking — resolving to
    /// `.discardEmpty` here would expunge the draft the user came back for.
    func testEmptiedRichPaneOverAResumedDraftStaysContent() throws {
        let seed = Draft(body: "the draft I saved yesterday")
        let model = try TestFixtures.makeComposeModel(seed: seed, signature: Self.signature)
        model.richMirrorsMarkdown = false

        XCTAssertNotEqual(model.markdownBody, Self.signatureSeed)
        XCTAssertTrue(model.hasDraftContent(bodies: Self.bodiesForEmptiedRichPane(model.markdownBody)))
    }

    /// Same for a reply's attribution + quoted original.
    func testEmptiedRichPaneOverAReplyStaysContent() throws {
        let seed = Draft(body: "\n\nOn Tuesday, someone wrote:\n\n> the original")
        let model = try TestFixtures.makeComposeModel(seed: seed, signature: Self.signature)
        model.richMirrorsMarkdown = false

        XCTAssertTrue(model.hasDraftContent(bodies: Self.bodiesForEmptiedRichPane(model.markdownBody)))
    }

    /// With no signature there is no seed, the emptied pane converts to
    /// `("", "")`, and the composer was already silent — the arm the
    /// verifier used to isolate the trigger. Pinned so it stays that way.
    func testEmptiedRichPaneWithNoSignatureIsNotContent() throws {
        let model = try TestFixtures.makeComposeModel()
        model.richMirrorsMarkdown = false

        XCTAssertEqual(model.markdownBody, "")
        XCTAssertFalse(model.hasDraftContent(bodies: ComposeBodies(text: "", html: "", source: .empty)))
    }

    // MARK: - The pure rules

    /// An emptied rich pane leaves `source` no rich content to prefer, so
    /// it falls through to the Markdown seed — the branch that carries the
    /// signature into the parts, and the reason `hasDraftContent` needs the
    /// decision rather than the parts.
    func testEmptyRichPaneResolvesToMarkdownEvenAfterTyping() {
        let source = ComposeBodyPolicy.source(
            richHTML: "",
            richMirrorsMarkdown: false,
            markdownBody: Self.signatureSeed,
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .markdown)
        XCTAssertFalse(source.richPaneAuthored)
    }

    /// The scaffolding WebKit leaves behind is not empty to `source` — it
    /// reads as authored rich copy. Cause 1 is what keeps that string from
    /// ever reaching here; this pins why cause 2 alone was not enough.
    func testResidualParagraphMarkupWouldReadAsAuthoredRichCopy() {
        let source = ComposeBodyPolicy.source(
            richHTML: "<p><br></p>",
            richMirrorsMarkdown: false,
            markdownBody: Self.signatureSeed,
            markdownUserEdited: false
        )

        XCTAssertEqual(source, .rich)
        XCTAssertTrue(source.richPaneAuthored)
    }

    /// The rule itself: an unauthored rich pane over an untouched signature
    /// seed is the signature and nothing else, whether the pane is empty or
    /// mirroring the seed.
    func testPolicyAcceptsAnUnauthoredRichPane() {
        XCTAssertTrue(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: Self.signatureSeed,
                richPaneAuthored: false,
                signatureOnlySeed: Self.signatureSeed
            )
        )
        XCTAssertFalse(
            ComposeBodyPolicy.bodyIsUntouchedSignature(
                markdownBody: Self.signatureSeed,
                richPaneAuthored: true,
                signatureOnlySeed: Self.signatureSeed
            ),
            "the rich pane holds a second copy"
        )
    }
}
