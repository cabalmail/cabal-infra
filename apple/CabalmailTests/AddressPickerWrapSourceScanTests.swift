import XCTest

// Regression coverage for #1597.
//
// Three surfaces #1587 left raw, plus two more the verification found in the
// same file, drew a whole address in a `Text` or `Label`. An address is one
// unbreakable token, so wherever a row wrapped one the layout engine
// hyphenated it and drew a character the address does not contain, measured
// on iPhone 17:
//
// - `FromPicker`'s field label: `verificationpass1597abcde-` /
//   `fghijklmnopqrstuvwx@longsubdomain-` / `probe0916.cabal-mail.com`.
// - `FromPicker`'s menu rows, the plain one and the checked `Label`:
//   `7.te876d@pouls-f0k.cabal-mail.io` for an address with no hyphen there.
// - The Settings ▸ Composing Default From picker rows: `…poulsf0k.ca-` /
//   `bal-mail.io`.
// - `RuleEditorExtras`' forward-address list: `…@longsubdomain-` /
//   `probe0916.cabal-mail.com`.
//
// `AddressDisplay.wrappable` is the fix #1547 established. The scan pins two
// things, because none of these views has a seam for either rule:
//
// 1. No raw address reaches a `Text` or `Label` in these files, and each site
//    draws either the wrappable address or — for the three *menu rows*, since
//    #1702 — `AddressMenuTitlePolicy`'s title, which is the wrappable one
//    everywhere except macOS. The zero-width spaces are what AppKit compares
//    typed characters against, so in an `NSMenuItem` title they defeated
//    type-to-select and highlighted a different address; an AppKit menu row
//    never wraps, so it has nothing to spend them on. `AddressMenuTitlePolicyTests`
//    owns that rule; the counts below are what it left of this one.
// 2. Every wrappable draw carries a raw `accessibilityLabel`. Measured on
//    iPhone 17 it holds for the From field and both kinds of From menu row
//    (0 zero-width spaces in the AX label); the menu-style Settings `Picker`
//    drops it and its rows read with the zero-width spaces in, as a
//    `confirmationDialog` title does (#1547). The Picker's selection and the
//    From field's value are the raw `address.address` either way; only the
//    drawn string changed.
//
// Shape copied from `AddressListRowWrapSourceScanTests`, keyed by path.
final class AddressPickerWrapSourceScanTests: XCTestCase {

    /// Each file, with the wrappable draws and raw labels it must carry. The
    /// two menu-holding files draw fewer than they did before #1702: the From
    /// menu's two rows and the Default From picker's row take their title from
    /// `AddressMenuTitlePolicy` instead, which is the wrappable string on every
    /// platform whose rows wrap.
    private struct Expectation {
        let wrappable: Int
        let menuTitles: Int
        let rawLabels: [String]
    }

    private static let expected: [String: Expectation] = [
        "Cabalmail/Views/FromPicker.swift": Expectation(
            wrappable: 1,
            menuTitles: 2,
            rawLabels: [".accessibilityLabel(fromAddress)", ".accessibilityLabel(address.address)"]
        ),
        "Cabalmail/Views/RuleEditorExtras.swift": Expectation(
            wrappable: 1, menuTitles: 0, rawLabels: [".accessibilityLabel(address)"]
        ),
        "Cabalmail/Views/SettingsDetailViews.swift": Expectation(
            wrappable: 0, menuTitles: 1, rawLabels: [".accessibilityLabel(address.address)"]
        ),
    ]

    /// Rule 1: nothing draws a raw address, and every site draws either the
    /// wrappable one or a menu title derived from it.
    func testEverySiteDrawsTheWrappableAddress() throws {
        var offenders: [String: Int] = [:]
        for (path, want) in Self.expected {
            let code = Self.code(in: try Self.source(path))
            let raw = try Self.rawAddressHits(in: code)
            if raw > 0 { offenders[path] = raw }
            XCTAssertEqual(
                code.components(separatedBy: "AddressDisplay.wrappable(").count - 1,
                want.wrappable,
                "\(path): draw each non-menu address through AddressDisplay.wrappable (#1597)"
            )
            XCTAssertEqual(
                try Self.menuTitleHits(in: code),
                want.menuTitles,
                "\(path): draw each menu row through AddressMenuTitlePolicy (#1702)"
            )
        }
        XCTAssertEqual(offenders, [:], "a raw address Text/Label hyphenates when it wraps (#1597)")
    }

    /// Rule 2: VoiceOver reads the raw address, not the zero-width spaces.
    func testEveryWrappableDrawKeepsTheRawAccessibilityLabel() throws {
        for (path, want) in Self.expected {
            let code = Self.code(in: try Self.source(path))
            for label in want.rawLabels {
                XCTAssertTrue(code.contains(label), "\(path): missing \(label) (#1597)")
            }
        }
    }

    /// The detector on synthetic snippets, including each reported shape.
    func testDetectorCatchesTheReportedShapes() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.address)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: #"Label(address.address, systemImage: "checkmark")"#), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: #"Text(model.fromAddress ?? "Select an address…")"#), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.address).tag(Optional(address.address))"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(AddressDisplay.wrappable(address.address))"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Label(AddressDisplay.wrappable(a), systemImage: \"x\")"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: ".accessibilityLabel(address.address)"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: #"Label("Create new address…", systemImage: "plus")"#), 0)
        XCTAssertEqual(try Self.menuTitleHits(in: "Text(menuTitle(address))"), 1)
        XCTAssertEqual(
            try Self.menuTitleHits(in: #"Label(menuTitle(address), systemImage: "checkmark")"#), 1
        )
        XCTAssertEqual(
            try Self.menuTitleHits(in: "Text(AddressMenuTitlePolicy.rowTitle(address.address, on: .current))"), 1
        )
        XCTAssertEqual(try Self.menuTitleHits(in: "Text(AddressDisplay.wrappable(address.address))"), 0)
    }

    /// A comment explaining the rule names the raw call, and is not one.
    func testTheScanReadsCodeNotProse() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: Self.code(in: "/// was Text(address.address)")), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: Self.code(in: "Text(address) // old")), 1)
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourcesAreReadable() throws {
        XCTAssertTrue(try Self.source("Cabalmail/Views/FromPicker.swift").contains("struct FromPicker: View"))
        XCTAssertTrue(try Self.source("Cabalmail/Views/RuleEditorExtras.swift").contains("struct ForwardAddressList"))
        XCTAssertTrue(try Self.source("Cabalmail/Views/SettingsDetailViews.swift").contains(#"Picker("Default From""#))
    }

    // MARK: - Corpus

    /// `Text(`/`Label(` opening on a bare address expression: `address`,
    /// `x.address` or `x.fromAddress`, followed by `)`, `,` or `??`.
    private static func rawAddressHits(in body: String) throws -> Int {
        try body.ranges(of: Regex(#"\b(?:Text|Label)\(\s*(?:\w+\.)*(?:address|fromAddress)\s*(?:\)|,|\?\?)"#)).count
    }

    /// A menu row's title: `menuTitle(...)` in the From menu, or the policy
    /// called by name as the Default From picker row does.
    private static func menuTitleHits(in body: String) throws -> Int {
        try body.ranges(
            of: Regex(#"\b(?:Text|Label)\(\s*(?:menuTitle\(|AddressMenuTitlePolicy\.rowTitle\()"#)
        ).count
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source(_ path: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
