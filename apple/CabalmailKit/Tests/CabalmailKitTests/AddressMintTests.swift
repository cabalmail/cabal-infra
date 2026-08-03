import XCTest
@testable import CabalmailKit

final class AddressMintTests: XCTestCase {
    /// SplitMix64 — deterministic across runs and platforms.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
            return mixed ^ (mixed >> 31)
        }
    }

    func testRandomLabelUsesDefaultLengthAndAlphabet() {
        var generator = SeededGenerator(state: 42)
        let label = AddressMint.randomLabel(using: &generator)
        XCTAssertEqual(label.count, AddressMint.randomLabelLength)
        XCTAssertTrue(label.allSatisfy { AddressMint.labelAlphabet.contains($0) })
    }

    func testRandomLabelHonorsCustomLength() {
        var generator = SeededGenerator(state: 7)
        XCTAssertEqual(AddressMint.randomLabel(length: 12, using: &generator).count, 12)
        XCTAssertEqual(AddressMint.randomLabel(length: 0, using: &generator), "")
        XCTAssertEqual(AddressMint.randomLabel(length: -3, using: &generator), "")
    }

    func testNormalizeLabelBasics() {
        XCTAssertEqual(AddressMint.normalizeLabel("Acme"), "acme")
        XCTAssertEqual(AddressMint.normalizeLabel("Acme Complaints"), "acme-complaints")
        XCTAssertEqual(AddressMint.normalizeLabel("  spaced   out  "), "spaced-out")
        XCTAssertEqual(AddressMint.normalizeLabel("foo_bar.baz"), "foo-bar-baz")
        XCTAssertEqual(AddressMint.normalizeLabel("already-fine-42"), "already-fine-42")
    }

    func testNormalizeLabelFoldsAndDropsExotics() {
        XCTAssertEqual(AddressMint.normalizeLabel("café"), "cafe")
        XCTAssertEqual(AddressMint.normalizeLabel("don't"), "dont")
        XCTAssertEqual(AddressMint.normalizeLabel("a✨b"), "ab")
        XCTAssertEqual(AddressMint.normalizeLabel("-leading and trailing-"), "leading-and-trailing")
    }

    func testNormalizeLabelRejectsEmptyResults() {
        XCTAssertNil(AddressMint.normalizeLabel(""))
        XCTAssertNil(AddressMint.normalizeLabel("   "))
        XCTAssertNil(AddressMint.normalizeLabel("!!!"))
        XCTAssertNil(AddressMint.normalizeLabel("✨✨"))
    }

    func testNormalizeLabelCapsAtDnsLabelLimit() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(AddressMint.normalizeLabel(long)?.count, 63)
    }

    func testNormalizeLabelTrimsHyphenAtCapBoundary() {
        // The 63rd char lands on a separator-inserted hyphen — trimmed so
        // the result stays a valid DNS label.
        let raw = String(repeating: "a", count: 62) + " b"
        XCTAssertEqual(AddressMint.normalizeLabel(raw), String(repeating: "a", count: 62))
    }
}
