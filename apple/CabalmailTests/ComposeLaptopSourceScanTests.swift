import XCTest

// Compose's laptop pose moves the body and the fields by value: the form's
// sections reorder in one `ForEach` keyed by section, and the body's height,
// the formatting controls and the bars change through modifiers that are
// always present. An `.id`, an `AnyView` or a second mount of the body would
// rebuild the editor's web view on a fold and drop its caret, its undo and
// the keyboard (measured on the Duo simulator, 2026-10-31). The views have
// no unit seam, so this reads the source, in the shape the other
// `*SourceScanTests` set, with comments stripped so a doc comment can't stand
// in for code.
final class ComposeLaptopSourceScanTests: XCTestCase {
    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func code(_ path: String) throws -> String {
        let body = try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
        return withoutComments(body)
    }

    private static func withoutComments(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    private static func occurrences(of needle: String, in body: String) -> Int {
        body.components(separatedBy: needle).count - 1
    }

    /// The body is mounted once on iOS and once in the Mac layout, both in
    /// `ComposeView`: a laptop copy would fight the other for the one web
    /// view.
    func testTheBodyIsMountedTwiceBothInComposeView() throws {
        var mounts: [String: Int] = [:]
        let root = Self.apple.appendingPathComponent("CabalmailUI")
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walk where url.pathExtension == "swift" {
            let body = Self.withoutComments(try String(contentsOf: url, encoding: .utf8))
            let count = Self.occurrences(of: "ComposerBody(", in: body)
            if count > 0 { mounts[url.lastPathComponent] = count }
        }
        XCTAssertEqual(mounts, ["ComposeView.swift": 2])
    }

    /// The form draws its sections in the laptop-aware order, which ties the
    /// case-order tests to what renders everywhere but laptop pose.
    func testTheFormReadsTheLaptopOrder() throws {
        let view = try Self.code("CabalmailUI/Compose/ComposeView.swift")
        XCTAssertTrue(view.contains("ForEach(ComposeFormSection.order(inLaptop: laptop.isLaptop), id: \\.self)"))
    }

    /// The laptop files change values only.
    func testTheLaptopFilesHoldNoIdentityChanges() throws {
        for path in [
            "CabalmailUI/Compose/ComposeLaptopArrangement.swift",
            "CabalmailUI/Compose/ComposeLaptopReader.swift",
            "CabalmailUI/Shared/Chrome/CollapsesByValue.swift",
        ] {
            let body = try Self.code(path)
            XCTAssertFalse(body.isEmpty, "\(path) is missing")
            XCTAssertFalse(body.contains(".id("), "\(path) re-identifies a view")
            XCTAssertFalse(body.contains("AnyView"), "\(path) erases a view's type")
        }
    }

    /// The detectors have teeth: a comment is stripped, and a stray `.id(`
    /// would be seen.
    func testTheDetectorsSeeWhatTheyLookFor() {
        XCTAssertEqual(Self.withoutComments("a // ComposerBody(model: model)"), "a ")
        XCTAssertEqual(Self.occurrences(of: "ComposerBody(", in: "ComposerBody(x) ComposerBody(y)"), 2)
        XCTAssertTrue("view.id(laptop)".contains(".id("))
    }
}
