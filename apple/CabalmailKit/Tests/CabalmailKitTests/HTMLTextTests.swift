import XCTest
@testable import CabalmailKit

final class HTMLTextTests: XCTestCase {
    func testStripsTagsWithoutConcatenatingWords() {
        let html = "<table><tr><td>Order</td><td>shipped</td></tr></table>"
        XCTAssertEqual(HTMLText.plainText(from: html), "Order shipped")
    }

    func testDropsScriptStyleAndComments() {
        let html = """
        <html><head>
        <style>body { color: red; }</style>
        <SCRIPT type="text/javascript">var tracking = "beacon";</SCRIPT>
        </head><body>
        <!-- preheader: hidden -->
        <p>Your receipt is attached.</p>
        </body></html>
        """
        XCTAssertEqual(HTMLText.plainText(from: html), "Your receipt is attached.")
    }

    func testDecodesEntities() {
        let html = "<p>Fish &amp; chips &ndash; &#163;12&#x2026; &quot;great&quot;&nbsp;value</p>"
        XCTAssertEqual(
            HTMLText.plainText(from: html),
            "Fish & chips – £12… \"great\" value"
        )
    }

    func testUnknownEntityAndBareAmpersandPassThrough() {
        XCTAssertEqual(HTMLText.plainText(from: "AT&T &bogus; R&D"), "AT&T &bogus; R&D")
    }

    func testCollapsesWhitespaceAcrossBlocks() {
        let html = "<div>\n  one\n</div>\n\n<div>two<br>three</div>"
        XCTAssertEqual(HTMLText.plainText(from: html), "one two three")
    }

    func testImageOnlyBodyYieldsEmpty() {
        XCTAssertEqual(HTMLText.plainText(from: "<body><img src=\"cid:logo\"></body>"), "")
    }

    func testPlainProseSurvivesUntouched() {
        XCTAssertEqual(
            HTMLText.plainText(from: "Meet at 5 > 4 o'clock, if a < b."),
            // A stray `<` opens an unterminated pseudo-tag only if a `>`
            // follows; here the strip leaves prose intact.
            "Meet at 5 > 4 o'clock, if a < b."
        )
    }
}
