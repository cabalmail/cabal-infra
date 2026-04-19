import XCTest
@testable import CabalmailKit

final class SignatureFormatterTests: XCTestCase {
    func testEmptySignatureReturnsBaseUnchanged() {
        XCTAssertEqual(SignatureFormatter.seedBody(base: "", signature: ""), "")
        XCTAssertEqual(SignatureFormatter.seedBody(base: "hello", signature: ""), "hello")
    }

    func testEmptyBaseWithSignatureLandsSignatureBelowBlankLine() {
        let result = SignatureFormatter.seedBody(base: "", signature: "Alice")
        XCTAssertEqual(result, "\n\n-- \nAlice")
    }

    /// Reply / forward bodies lead with `"\n\n"` before the attribution
    /// line. The signature goes in front so the user's reply text — which
    /// lands at the top of the body — sits above the signature and the
    /// signature sits above the attribution.
    func testReplyBaseInsertsSignatureAboveQuotedBlock() {
        let base = "\n\nOn date, Someone wrote:\n> original"
        let result = SignatureFormatter.seedBody(base: base, signature: "Alice")
        XCTAssertEqual(result, "\n-- \nAlice\n\nOn date, Someone wrote:\n> original")
    }

    /// A legacy seed body that doesn't begin with `\n\n` still gets the
    /// signature prepended with a line break preserved so the signature
    /// renders on its own line.
    func testArbitraryBasePrefixesSignatureWithLineBreak() {
        let result = SignatureFormatter.seedBody(base: "pre-existing", signature: "Alice")
        XCTAssertEqual(result, "\n-- \nAlice\npre-existing")
    }

    func testMultiLineSignature() {
        let signature = "Alice Carroll\nCabalmail"
        let result = SignatureFormatter.seedBody(base: "", signature: signature)
        XCTAssertEqual(result, "\n\n-- \nAlice Carroll\nCabalmail")
    }
}
