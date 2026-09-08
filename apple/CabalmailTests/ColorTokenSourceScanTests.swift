import XCTest
@testable import Cabalmail

// The source-level half of the colour-token adoption (docs/1.x/color-tokens-plan.md).
//
// #1456 showed the failure mode: a rule for one colour lived in a doc
// comment, seven sites kept naming the platform colour themselves, and five
// of them measured under the WCAG floor. `WarningTintSourceScanTests` closed
// that for orange. This suite is its successor for the whole palette: every
// semantic colour now comes from `ColorTokens` (generated from
// `design/color-tokens.json`, where each value is held to its floor on every
// surface), so no view in any app target may name a platform colour, or the
// `AccentColor` asset, for itself.
//
// `.gray` is deliberately outside the pattern: it is the neutral for the
// debug log level and the un-favourite swipe, not a semantic colour, and the
// platform's grey is appearance-aware already.
final class ColorTokenSourceScanTests: XCTestCase {

    /// Sites where a literal platform colour is correct and stays. Empty
    /// today; a future entry needs the reason written beside it, keyed by
    /// path under `apple/` (not by filename — #1207).
    private static let allowed: [String: Int] = [:]

    func testNoViewNamesAPlatformColourItself() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(
            sources.count, 40,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )
        for probe in [
            "Cabalmail/ContentView.swift",
            "CabalmailMac/CabalmailMacApp.swift",
            "CabalmailWatch/ContentView.swift",
        ] {
            XCTAssertNotNil(sources[probe], "\(probe) is missing from the corpus")
        }

        var offenders: [String: Int] = [:]
        for (name, body) in sources {
            let hits = try Self.platformColourHits(in: body)
            if hits > 0 { offenders[name] = hits }
        }

        XCTAssertEqual(
            offenders, Self.allowed,
            "a coloured surface must read a ColorTokens value, not name a platform colour (#1456, colour audit)"
        )
    }

    /// The detector on synthetic snippets, so a rewrite of the views cannot
    /// quietly make the scan above vacuous.
    func testDetectorCatchesTheReportedShapes() throws {
        XCTAssertEqual(try Self.platformColourHits(in: ".foregroundStyle(.orange)"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: ".foregroundStyle(.red)"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: "        case .warn:  return .blue"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: ".tint(address.favorite ? .gray : .yellow)"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: "Color.green"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: "Color(\"AccentColor\")"), 1)
        XCTAssertEqual(try Self.platformColourHits(in: "case \"teal\": .teal"), 1)
        // Tokens, neutrals, and the environment accent are not hits.
        XCTAssertEqual(try Self.platformColourHits(in: ".foregroundStyle(ColorTokens.warningFg)"), 0)
        XCTAssertEqual(try Self.platformColourHits(in: ".foregroundStyle(.secondary)"), 0)
        XCTAssertEqual(try Self.platformColourHits(in: "Color.gray.opacity(0.15)"), 0)
        XCTAssertEqual(try Self.platformColourHits(in: ".tint(.accentColor)"), 0)
        // An enum case or identifier that merely contains a colour word.
        XCTAssertEqual(try Self.platformColourHits(in: "case .redraw: return .redacted"), 0)
        XCTAssertEqual(try Self.platformColourHits(in: "let bluetooth = .blueprint"), 0)
        // A mention in a comment cannot draw anything.
        XCTAssertEqual(try Self.platformColourHits(in: "/// why a plain `.orange` didn't clear the floor"), 0)
        XCTAssertEqual(try Self.platformColourHits(in: "Label(x) // was .orange\n.foregroundStyle(.orange)"), 1)
    }

    /// Line comments are cut first: a doc comment naming a colour is a
    /// description of the rule, not a use of it.
    private static func platformColourHits(in body: String) throws -> Int {
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        let names = "red|orange|yellow|green|blue|teal|indigo|purple|pink"
        let pattern = #"(?:\.|\bColor\.)(?:"# + names + #")\b|Color\("AccentColor"\)"#
        return try code.ranges(of: Regex(pattern)).count
    }

    /// Every Swift source in the three app targets, keyed by its path under
    /// `apple/`. Rooted off this file's own compile-time path so the scan
    /// follows the checkout wherever it lives. The watch target is in the
    /// scan now: it compiles `CabalmailKit`, so it has the tokens.
    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["Cabalmail", "CabalmailMac", "CabalmailWatch"] {
            let root = apple.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let key = url.standardizedFileURL.path
                    .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
                found[key] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }
}
