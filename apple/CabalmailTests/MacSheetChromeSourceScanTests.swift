import XCTest
@testable import Cabalmail

// Regression coverage for issues #1484 and #1501 (and the other half of
// #1063).
//
// macOS `Form` promotes a control's title into an external leading label
// column and gives its rows no horizontal content margins. Inside a sheet
// that draws the column hard against the sheet's left border and stretches
// the fields flush to the right one: the New Folder sheet's "Parent folder"
// label sat 1 pt from the sheet's edge while its siblings were inset 88 pt,
// and the name field ran to the border.
//
// `NewAddressSheet` had already met this and hand-built its macOS layout,
// with the reason in a comment. `NewFolderSheet` had not, so the rule
// existed in one place and was missing in the other — the shape that keeps
// producing this defect. The layout is now `MacSheetForm`, and this suite
// proves the form sheets ask it rather than keeping private copies.
//
// `SearchFiltersSheet` was the one sheet left drawing a bare `Form` on
// macOS (#1501): its "Subject" label sat 0 pt from the left border and all
// three text fields ran to the right one. It now asks the same chrome.
//
// Deleting the `#if os(macOS)` branch from any of them fails
// `testFormSheetsAskTheSharedChrome` by name.
final class MacSheetChromeSourceScanTests: XCTestCase {

    /// The sheets the shared chrome exists for: the two "create X" sheets
    /// (#1484) and the search Filters sheet (#1501).
    private static let formSheets = [
        "Cabalmail/Views/NewAddressSheet.swift",
        "Cabalmail/Views/NewFolderSheet.swift",
        "Cabalmail/Views/SearchFiltersSheet.swift",
    ]

    /// Each form sheet routes its macOS layout through `MacSheetForm`, and
    /// none leaves a `Form` on that path.
    func testFormSheetsAskTheSharedChrome() throws {
        let sheets = try Self.sheetSources()
        for path in Self.formSheets {
            let body = try XCTUnwrap(sheets[path], "\(path) is missing from the corpus")
            let mac = Self.macReachable(body)
            XCTAssertTrue(
                mac.contains("MacSheetForm {"),
                "\(path): build the macOS layout with MacSheetForm (#1484)"
            )
            XCTAssertEqual(
                try Self.bareFormHits(in: mac), 0,
                "\(path): a bare Form on the macOS path draws on the sheet's border (#1484)"
            )
        }
    }

    /// The numbers live in `MacSheetForm`, not in the sheets that use it —
    /// a second copy is what let the two create sheets disagree.
    func testFormSheetsDoNotRestateTheChromesNumbers() throws {
        let sheets = try Self.sheetSources()
        var offenders: [String] = []
        for path in Self.formSheets {
            let mac = Self.macReachable(try XCTUnwrap(sheets[path]))
            if mac.contains(".padding(24)") || mac.contains("frame(width: 460") {
                offenders.append(path)
            }
        }
        XCTAssertEqual(offenders, [], "ask MacSheetForm for the margins (#1484)")
    }

    /// Inventory: no sheet draws a macOS-reachable `Form`. The last known
    /// one was `SearchFiltersSheet` (#1501); a new offender fails here by
    /// path.
    func testNoSheetStillDrawsAMacForm() throws {
        let sheets = try Self.sheetSources()
        XCTAssertGreaterThan(
            sheets.count, 5,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )
        for probe in Self.formSheets {
            XCTAssertNotNil(sheets[probe], "\(probe) is missing from the corpus")
        }
        var offenders: [String] = []
        for (path, body) in sheets where try Self.bareFormHits(in: Self.macReachable(body)) > 0 {
            offenders.append(path)
        }
        offenders.sort()
        XCTAssertEqual(
            offenders, [],
            "a sheet put a Form on the macOS path — give it MacSheetForm (#1484, #1501)"
        )
    }

    /// Proves the conditional-compilation reader catches the reported
    /// shapes, on synthetic snippets rather than on the corpus — so a
    /// rewrite of the sheets cannot quietly make the scan above vacuous.
    func testDetectorReadsTheConditionals() throws {
        // The chrome's own name ends in `Form`, so a substring search reports
        // every fixed sheet as an offender — the first cut of this scan did.
        XCTAssertEqual(try Self.bareFormHits(in: "MacSheetForm {"), 0)
        XCTAssertEqual(try Self.bareFormHits(in: "Form {"), 1)
        XCTAssertEqual(try Self.bareFormHits(in: "            Form {"), 1)

        XCTAssertTrue(Self.macReachable("Form {").contains("Form {"))
        XCTAssertFalse(Self.macReachable("#if os(iOS)\nForm {\n#endif").contains("Form {"))
        XCTAssertFalse(
            Self.macReachable("#if os(iOS) || os(visionOS)\nForm {\n#endif").contains("Form {")
        )
        XCTAssertFalse(Self.macReachable("#if !os(macOS)\nForm {\n#endif").contains("Form {"))
        XCTAssertTrue(Self.macReachable("#if os(macOS)\nForm {\n#endif").contains("Form {"))
        // The `#else` of a non-macOS branch is the macOS branch, and the
        // `#else` of a macOS branch is not — the shape the sheets use.
        XCTAssertTrue(Self.macReachable("#if os(iOS)\nA()\n#else\nForm {\n#endif").contains("Form {"))
        XCTAssertFalse(
            Self.macReachable("#if os(macOS)\nA()\n#else\nForm {\n#endif").contains("Form {")
        )
        // Nesting: an iOS-only region inside a macOS one is still not macOS.
        XCTAssertFalse(
            Self.macReachable("#if os(macOS)\n#if os(iOS)\nForm {\n#endif\n#endif").contains("Form {")
        )
        // A doc comment naming the type is prose, not a declaration.
        XCTAssertFalse(Self.macReachable("/// A Form { on macOS draws").contains("Form {"))
    }

    // MARK: - Detectors

    /// Occurrences of a `Form { ... }` body. Anchored on a word boundary so
    /// `MacSheetForm {` — which ends in the same five characters — does not
    /// count as one.
    private static func bareFormHits(in body: String) throws -> Int {
        body.ranges(of: try Regex(#"\bForm\s*\{"#)).count
    }

    /// The source that survives conditional compilation for macOS, with
    /// line comments cut first.
    private static func macReachable(_ body: String) -> String {
        // Each element is "is this region compiled for macOS", nested.
        var stack: [Bool] = []
        var kept: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                stack.append(compiledForMac(trimmed.dropFirst(4)) && (stack.last ?? true))
            } else if trimmed.hasPrefix("#elseif ") {
                guard !stack.isEmpty else { continue }
                let enclosing = stack.dropLast().last ?? true
                stack[stack.count - 1] = compiledForMac(trimmed.dropFirst(8)) && enclosing
            } else if trimmed == "#else" {
                guard !stack.isEmpty else { continue }
                let enclosing = stack.dropLast().last ?? true
                stack[stack.count - 1] = !stack[stack.count - 1] && enclosing
            } else if trimmed == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
            } else if stack.allSatisfy({ $0 }) {
                kept.append(String(line))
            }
        }
        return kept.joined(separator: "\n")
    }

    /// Whether a `#if` condition holds when compiling for macOS. Unknown
    /// conditions are read as holding, so the scan errs towards reporting a
    /// `Form` rather than towards passing.
    private static func compiledForMac(_ condition: some StringProtocol) -> Bool {
        let text = String(condition)
        if text.contains("!os(macOS)") { return false }
        if text.contains("os(macOS)") || text.contains("canImport(AppKit)") { return true }
        let nonMac = ["os(iOS)", "os(visionOS)", "os(watchOS)", "os(tvOS)", "canImport(UIKit)"]
        return !nonMac.contains { text.contains($0) }
    }

    /// Every sheet view in the shared view tree, keyed by its path under
    /// `apple/`. Rooted off this file's own compile-time path so the scan
    /// follows the checkout wherever it lives.
    private static func sheetSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        let views = apple.appendingPathComponent("Cabalmail/Views")
        var found: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" && url.lastPathComponent.hasSuffix("Sheet.swift") {
            let key = url.standardizedFileURL.path
                .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
            found[key] = try String(contentsOf: url, encoding: .utf8)
        }
        return found
    }
}
