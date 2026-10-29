import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What "Open in New Window" hands the new window (`ComposeSnapshot`): the
/// sheet's composer as it stands, so the window carries on with the same
/// draft rather than starting a new one from it. Built from a seed, a
/// snapshot signs the body; captured from a composer, it copies what is
/// there, so a moved draft is never signed twice, and a moved reply keeps
/// its title, its focus rule and its rich pane as typed.
@MainActor
final class ComposeSnapshotTests: XCTestCase {

    func testASeedSignsOnceAndACaptureCopiesVerbatim() async throws {
        let sheet = try TestFixtures.makeComposeModel(seed: Draft(body: "Hello"), signature: "Yours, Sig")
        let signed = sheet.markdownBody
        XCTAssertEqual(signed.components(separatedBy: "Yours, Sig").count - 1, 1, signed)
        try await TestFixtures.requireEditorBridge(sheet)

        let snapshot = try await ComposeSnapshot.capture(from: sheet)
        XCTAssertEqual(snapshot.markdownBody, signed)
        XCTAssertEqual(snapshot.seededMarkdownBody, sheet.seededMarkdownBody)

        let handoffs = ComposeHandoffs()
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(
            for: snapshot.draftID, from: handoffs, signature: "Yours, Sig"
        )
        XCTAssertEqual(window.markdownBody, signed, "the moved body was signed again")
        XCTAssertFalse(window.markdownUserEdited, "the signed seed still reads as a seed in the window")
    }

    func testCaptureCarriesTheInlineImages() async throws {
        let sheet = try TestFixtures.makeComposeModel()
        _ = sheet.inlineImages.add(InlineImageEncoding.Encoded(data: Data([0xFF, 0xD8, 0xFF]), format: .jpeg))
        try await TestFixtures.requireEditorBridge(sheet)

        let snapshot = try await ComposeSnapshot.capture(from: sheet)
        let handoffs = ComposeHandoffs()
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)

        XCTAssertEqual(window.inlineImages, sheet.inlineImages)
        XCTAssertEqual(window.inlineImages.images.count, 1)
    }

    func testCaptureCarriesEveryField() async throws {
        let sheet = try TestFixtures.makeComposeModel(seed: Draft(
            fromAddress: "me@reply.cabalmail.example",
            to: ["them@example.com"],
            cc: ["cc@example.com"],
            bcc: ["bcc@example.com"],
            subject: "Re: plans",
            body: "> quoted",
            inReplyTo: "<original@example.com>",
            references: ["<root@example.com>", "<original@example.com>"],
            composeIntent: .replyAll,
            serverUid: 785,
            serverUidValidity: 9,
            replySourceFolder: "INBOX",
            replySourceUid: 42
        ))
        sheet.markdownBody = "Typed in Markdown\n\n> quoted"
        sheet.editorMode = .markdown
        sheet.richMirrorsMarkdown = false
        sheet.addAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        sheet.adoptServerDraftRef(DraftServerRef(uid: 786, uidValidity: 9))
        sheet.availableAddresses = [Address(address: "me@reply.cabalmail.example", subdomain: "reply", tld: "example")]
        try await TestFixtures.requireEditorBridge(sheet)

        let snapshot = try await ComposeSnapshot.capture(from: sheet)
        let handoffs = ComposeHandoffs()
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)

        XCTAssertEqual(window.draftId, sheet.draftId)
        XCTAssertEqual(window.fromAddress, sheet.fromAddress)
        XCTAssertEqual(window.fromSeededFromPreference, sheet.fromSeededFromPreference)
        XCTAssertEqual(window.toText, sheet.toText)
        XCTAssertEqual(window.ccText, sheet.ccText)
        XCTAssertEqual(window.bccText, sheet.bccText)
        XCTAssertEqual(window.subject, sheet.subject)
        XCTAssertEqual(window.markdownBody, sheet.markdownBody)
        XCTAssertEqual(window.seededMarkdownBody, sheet.seededMarkdownBody)
        XCTAssertEqual(window.markdownUserEdited, true)
        XCTAssertEqual(window.richMirrorsMarkdown, false)
        XCTAssertEqual(window.editorMode, .markdown)
        XCTAssertEqual(window.attachments, sheet.attachments)
        XCTAssertEqual(window.serverDraftRef, DraftServerRef(uid: 786, uidValidity: 9))
        XCTAssertEqual(window.replacedServerDraftUIDs, [785], "the chain a send prunes from the Drafts list (#1071)")
        XCTAssertEqual(window.inReplyTo, sheet.inReplyTo)
        XCTAssertEqual(window.references, sheet.references)
        XCTAssertEqual(window.composeIntent, .replyAll)
        XCTAssertEqual(window.replySourceFolder, "INBOX")
        XCTAssertEqual(window.replySourceUid, 42)
        XCTAssertEqual(window.isResumedServerDraft, sheet.isResumedServerDraft)
        XCTAssertEqual(window.navigationTitle, sheet.navigationTitle)
        XCTAssertEqual(window.availableAddresses, sheet.availableAddresses)
    }

    func testRichTextSurvivesTheMove() async throws {
        let sheet = try TestFixtures.makeComposeModel()
        try await TestFixtures.requireEditorBridge(sheet)
        await sheet.editorController.setHTML("<p><strong>Bold</strong> and <em>leaning</em> words</p>")
        sheet.richMirrorsMarkdown = false
        let typed = try await sheet.editorController.checked.getHTML()

        let window = try await moved(sheet)

        let restored = try await window.editorController.checked.getHTML()
        XCTAssertEqual(restored, typed)
        XCTAssertTrue(restored.contains("<strong>Bold</strong>"), restored)
        XCTAssertFalse(window.richMirrorsMarkdown, "the rich pane is still the user's, not an echo of the Markdown")
    }

    /// A reply's rich pane opens with two blank paragraphs above the quote,
    /// and the user writes in it. The window takes the pane as it is, rather
    /// than rendering the seed again, which would drop what was written, or
    /// putting the two paragraphs in front of it a second time.
    func testAMovedReplyKeepsTitleFocusRuleAndNoSecondPrefix() async throws {
        let sheet = try TestFixtures.makeComposeModel(
            seed: Draft(subject: "Re: plans", body: "> quoted", composeIntent: .reply)
        )
        try await TestFixtures.requireEditorBridge(sheet)
        await sheet.start()
        sheet.stop()
        let seeded = try await sheet.editorController.checked.getHTML()
        await sheet.editorController.setHTML("<p>Sounds good.</p>" + seeded)
        sheet.richMirrorsMarkdown = false
        let written = try await sheet.editorController.checked.getHTML()
        XCTAssertNotEqual(written, seeded, "precondition: the pane differs from a render of the seed")

        let window = try await moved(sheet)

        let restored = try await window.editorController.checked.getHTML()
        XCTAssertEqual(restored, written)
        XCTAssertEqual(window.navigationTitle, "Reply")
        XCTAssertTrue(window.shouldFocusBodyOnAppear)
    }

    /// Captures `sheet`, offers it, and starts the window's composer in
    /// front, as the window opened for it does.
    private func moved(_ sheet: ComposeViewModel) async throws -> ComposeViewModel {
        let snapshot = try await ComposeSnapshot.capture(from: sheet)
        // The deadline runs from the offer, and the window's bridge boots
        // after it.
        let handoffs = ComposeHandoffs(sleep: TestFixtures.farHandoffDeadline)
        TestFixtures.offer(snapshot, on: handoffs)
        let window = try TestFixtures.makeMovedComposeModel(for: snapshot.draftID, from: handoffs)
        try await TestFixtures.requireEditorBridge(window)
        window.handoff?.sceneIsActive = true
        await window.start()
        window.stop()
        let outcome = await handoffs.outcome(for: snapshot.draftID)
        XCTAssertEqual(outcome, .claimed)
        return window
    }
}
