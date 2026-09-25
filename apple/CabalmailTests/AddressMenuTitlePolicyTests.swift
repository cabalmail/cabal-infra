import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for #1702.
//
// #1609 routed five address-drawing surfaces through `AddressDisplay.wrappable`
// so a wrapped address stops inventing a hyphen (#1597). Two of the five are
// AppKit menu rows, and there the zero-width spaces are what AppKit compares
// typed characters against: in Settings ▸ Composing ▸ Default From, `d`
// highlighted `daily@…` and `a` moved the highlight to a *different* address,
// which Return committed to `default_from_address`. The compose From menu did
// the same. A `U+200B` sorts below every letter, so from the second keystroke
// on the search buffer is past the intended row.
//
// The rule is about the platform: iOS/iPadOS/visionOS menu rows really do wrap
// (measured in #1597's retest) and have no type-to-select, macOS rows never
// wrap and do. So these pin both halves, plus the two call sites — a call site
// that goes back to `wrappable` directly puts the defect back on screen, and
// nothing else would catch it.
final class AddressMenuTitlePolicyTests: XCTestCase {

    private let sample = "daily@qa0722.cabal-mail.com"

    /// The reported failure: a macOS menu row's title is the address the user
    /// types, with nothing interleaved for type-to-select to trip over.
    func testMacOSMenuRowsDrawTheRawAddress() {
        XCTAssertEqual(AddressMenuTitlePolicy.rowTitle(sample, on: .macOS), sample)
        XCTAssertFalse(AddressMenuTitlePolicy.rowTitle(sample, on: .macOS).contains("\u{200B}"))
        XCTAssertFalse(AddressMenuTitlePolicy.rowMayCarryBreaks(on: .macOS))
    }

    /// The other half, and the reason this isn't a revert: the touch platforms'
    /// menu rows wrap over three lines and hyphenate without the breaks.
    func testTouchPlatformsKeepTheWrappableTitle() {
        for platform in [HostPlatform.iOS, .visionOS] {
            XCTAssertEqual(
                AddressMenuTitlePolicy.rowTitle(sample, on: platform),
                AddressDisplay.wrappable(sample),
                "\(platform) menu rows wrap, so they still need the break opportunities (#1597)"
            )
            XCTAssertTrue(AddressMenuTitlePolicy.rowMayCarryBreaks(on: platform))
        }
    }

    /// Whichever title is drawn, the visible characters are the address's own:
    /// the fix must not start hiding or adding any.
    func testNoPlatformAltersTheVisibleAddress() {
        for platform in [HostPlatform.macOS, .iOS, .visionOS, .watchOS] {
            let visible = AddressMenuTitlePolicy.rowTitle(sample, on: platform)
                .filter { $0 != "\u{200B}" }
            XCTAssertEqual(visible, sample, "\(platform) redrew the address itself")
        }
    }

    /// The policy is only worth anything if the running platform resolves to
    /// the case the rules above are written about. This suite is hosted by the
    /// macOS app target, so `.current` has to be `.macOS` here.
    func testCurrentResolvesToTheHostPlatform() {
        XCTAssertEqual(HostPlatform.current, .macOS)
    }

    // MARK: - Call sites

    /// Both menus ask the policy. Neither view's body is reachable from a unit
    /// test, so the call is read out of the source: a row that goes back to
    /// `AddressDisplay.wrappable` compiles, ships, and highlights the wrong
    /// address on macOS.
    func testBothMenuRowSitesRouteThroughThePolicy() throws {
        let sources = try Self.viewSources()
        for path in ["Cabalmail/Views/FromPicker.swift", "Cabalmail/Views/SettingsDetailViews.swift"] {
            let code = Self.code(in: try XCTUnwrap(sources[path], "\(path) is missing from the corpus"))
            XCTAssertTrue(
                code.contains("AddressMenuTitlePolicy.rowTitle("),
                "\(path): draw menu rows through AddressMenuTitlePolicy (#1702)"
            )
        }
    }

    /// The compose From menu's two branches — the checked row and the plain
    /// one — both take the policy's title. #1597's verification caught a fix
    /// that covered only one of them.
    func testBothComposeMenuBranchesTakeThePolicysTitle() throws {
        let code = Self.code(in: try XCTUnwrap(Self.viewSources()["Cabalmail/Views/FromPicker.swift"]))
        XCTAssertTrue(code.contains("Label(menuTitle(address), systemImage: \"checkmark\")"))
        XCTAssertTrue(code.contains("Text(menuTitle(address))"))
        XCTAssertEqual(
            try Self.wrappableMenuRowHits(in: code), 0,
            "a menu row drawing AddressDisplay.wrappable directly is the defect (#1702)"
        )
    }

    /// The From field's own label is NOT a menu row: it is wrapping SwiftUI
    /// text with no type-to-select, and it keeps the treatment (#1597).
    func testTheFromFieldLabelKeepsTheWrappableAddress() throws {
        let code = Self.code(in: try XCTUnwrap(Self.viewSources()["Cabalmail/Views/FromPicker.swift"]))
        XCTAssertTrue(
            code.contains("Text(AddressDisplay.wrappable(fromAddress))"),
            "the From field label wraps, so it still needs the break opportunities (#1597)"
        )
    }

    /// The detector on synthetic snippets, so a rewrite of the views can't
    /// make the scan above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.wrappableMenuRowHits(in: "Text(AddressDisplay.wrappable(address.address))"), 1)
        XCTAssertEqual(
            try Self.wrappableMenuRowHits(
                in: "Label(AddressDisplay.wrappable(address.address), systemImage: \"checkmark\")"
            ),
            1
        )
        XCTAssertEqual(try Self.wrappableMenuRowHits(in: "Text(menuTitle(address))"), 0)
        // The From field's label holds the selected address, not a row's.
        XCTAssertEqual(try Self.wrappableMenuRowHits(in: "Text(AddressDisplay.wrappable(fromAddress))"), 0)
    }

    /// Floor: a mis-rooted walk reads nothing and passes everything above.
    func testCorpusIsReadable() throws {
        let sources = try Self.viewSources()
        XCTAssertGreaterThanOrEqual(sources.count, 20, "the view corpus did not load")
        XCTAssertTrue(
            sources["Cabalmail/Views/AddressMenuTitlePolicy.swift"]?.contains("rowMayCarryBreaks") == true,
            "the policy itself is missing from the corpus"
        )
    }

    // MARK: - Corpus

    /// A menu row drawing `<anything>.address` through `wrappable`: the shape
    /// the defect shipped as.
    private static func wrappableMenuRowHits(in body: String) throws -> Int {
        try body.ranges(
            of: Regex(#"\b(?:Text|Label)\(\s*AddressDisplay\.wrappable\(\s*(?:\w+\.)+address\s*\)"#)
        ).count
    }

    /// `body` with line comments cut, so prose naming a call isn't one.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    /// Every Swift source under the shared view tree, keyed by its path under
    /// `apple/`.
    private static func viewSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        let root = apple.appendingPathComponent("Cabalmail/Views")
        var found: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return found
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let key = url.standardizedFileURL.path
                .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
            found[key] = try String(contentsOf: url, encoding: .utf8)
        }
        return found
    }
}
