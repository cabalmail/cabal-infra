import XCTest
@testable import Cabalmail

// Regression coverage for issue #858: a photo picked in the iPhone composer
// left no trace on screen — no chip, no count, no way to remove it — because
// the "Attachments" section rendered AFTER the body editor. The editor is
// greedy, so that section started below the fold, and the WKWebView ate the
// pan that would have scrolled to it, so the attachment could be neither
// reviewed nor removed and repeat picks silently piled up. Same trap as the
// send-blocking error banner in #812. Nothing actionable may follow
// `.message`.
final class ComposeFormSectionTests: XCTestCase {

    private func index(of section: ComposeFormSection) throws -> Int {
        try XCTUnwrap(ComposeFormSection.allCases.firstIndex(of: section))
    }

    func testAttachmentsRenderAboveTheBodyEditor() throws {
        XCTAssertLessThan(
            try index(of: .attachments),
            try index(of: .message),
            "attachments below the editor are unreachable: the WKWebView swallows the pan"
        )
    }

    func testTheBodyEditorIsLast() throws {
        XCTAssertEqual(
            ComposeFormSection.allCases.last,
            .message,
            "the greedy editor strands every section placed after it"
        )
    }

    // Issue #938: the error banner rode along as the first Form section.
    // Focusing Subject scrolls the form down for the keyboard, so a section
    // inserted at the top laid out 27pt above the sheet, behind the toolbar
    // — Save Draft looked dead. It is pinned above the scroll now, so no
    // scrolling section may claim the slot.
    func testTheErrorBannerIsNotAScrollingSection() throws {
        XCTAssertEqual(
            ComposeFormSection.allCases.first,
            .from,
            "the error banner is pinned, not scrolled: a section can be scrolled out of sight"
        )
    }
}
