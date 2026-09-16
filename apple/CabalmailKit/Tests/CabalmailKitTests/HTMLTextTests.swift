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

    // MARK: - firstLine

    func testFirstLineIsTheFirstBlockWithProse() {
        let html = "<figure><img src=\"x.jpg\"></figure><p>Lead <em>paragraph</em> &amp; more.</p><p>Second.</p>"
        XCTAssertEqual(HTMLText.firstLine(from: html), "Lead paragraph & more.")
    }

    func testLineBreaksAndCellsEndTheLine() {
        XCTAssertEqual(HTMLText.firstLine(from: "one<br>two"), "one")
        XCTAssertEqual(HTMLText.firstLine(from: "one<BR />two"), "one")
        XCTAssertEqual(HTMLText.firstLine(from: "<table><tr><td>Name</td><td>Value</td></tr></table>"), "Name")
        XCTAssertEqual(HTMLText.firstLine(from: "<h1>Heading</h1><p>Body</p>"), "Heading")
    }

    func testSkipsScriptStyleHeadCommentsAndBlankBlocks() {
        let html = """
        <html><head><title>Page</title></head><body>
        <style>p { color: red; }</style><SCRIPT>track()</SCRIPT><!-- <p>hidden</p> -->
        <p>&nbsp;</p><div>
          real
          text </div><p>next</p>
        """
        XCTAssertEqual(HTMLText.firstLine(from: html), "real text")
    }

    func testInlineTagsDoNotSplitWords() {
        XCTAssertEqual(
            HTMLText.firstLine(from: "<p>wor<b>d</b>s and <a href=\"u\">links</a></p>"),
            "words and links"
        )
    }

    func testDecodesEntitiesInTheLine() {
        XCTAssertEqual(HTMLText.firstLine(from: "<p>Fish &amp; chips &ndash; &#163;12</p>"), "Fish & chips – £12")
    }

    func testLongLineIsCutWithAnEllipsis() {
        let html = "<p>" + String(repeating: "word ", count: 200) + "</p>"
        XCTAssertEqual(HTMLText.firstLine(from: html, maxLength: 20), "word word word word…")
        // A single run far past the raw budget stops the scan early.
        XCTAssertEqual(HTMLText.firstLine(from: String(repeating: "a", count: 10_000), maxLength: 5), "aaaaa…")
    }

    func testShortLineHasNoEllipsis() {
        XCTAssertEqual(HTMLText.firstLine(from: "<p>Short.</p>", maxLength: 20), "Short.")
    }

    func testNoProseYieldsEmpty() {
        XCTAssertEqual(HTMLText.firstLine(from: ""), "")
        XCTAssertEqual(HTMLText.firstLine(from: "<img src=\"x\">"), "")
        XCTAssertEqual(HTMLText.firstLine(from: "<p>  </p><p>&nbsp;</p>"), "")
    }

    func testStrayAngleBracketsAreProse() {
        XCTAssertEqual(HTMLText.firstLine(from: "5 > 4 and a < b"), "5 > 4 and a < b")
        XCTAssertEqual(HTMLText.firstLine(from: "<p>I <3 feeds</p>"), "I <3 feeds")
    }
}
