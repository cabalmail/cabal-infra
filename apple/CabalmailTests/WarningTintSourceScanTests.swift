import XCTest
@testable import Cabalmail

// Regression coverage for issue #1456, the half that actually regressed.
//
// #1453 lifted the warning orange into a policy and pointed one call site at
// it. Seven others kept their own `.orange` — two message-row indicators,
// the reader's authentication warning sentence and its verdict chips, the
// `Suspended` caption under a suspended address, and the Diagnostics log's
// two `.warn` tints — and five of them measured under the WCAG floor on a
// light row, exactly as the one that was fixed had. Nothing connected the
// policy to the sites, so a rule that existed in a doc comment was a comment.
//
// This suite is therefore a source-level invariant, not a colour test:
// `WarningTintTests` proves the rule is right, and this one proves nobody
// answers the question on their own. Reverting a single call site to
// `.orange` fails `testNoViewPinsThePlatformOrangeItself` by name.
final class WarningTintSourceScanTests: XCTestCase {

    /// Where a literal `.orange` is correct and stays.
    ///
    /// - `WarningTint` is the rule itself: the one place the platform colour
    ///   may be named, and the dark appearance's branch is where it is drawn.
    /// - `FolderListView+Helpers` and `AddressListView` tint a **swipe
    ///   action**, i.e. the button's fill, which the system draws its own
    ///   white glyph on — the opposite arrangement from a foreground.
    /// - `ToastBanner`'s `.warning` and `SignedInRootView`'s offline banner
    ///   tint a filled banner for the same reason. #1456 scoped both out and
    ///   neither is measured here; if either is ever reported, it is a
    ///   background question and this list is where the answer goes.
    /// - `FlagPaletteSettingsView` maps the *stored palette name* `"orange"`
    ///   to a swatch. That is user data round-tripping through the API, not
    ///   a warning, and darkening it would silently rename the user's colour.
    ///
    /// The watch's three are deliberately absent from this map, because the
    /// scan below does not walk that target — see `appSources()`.
    ///
    /// Keyed by path under `apple/`, not by filename: `ContentView.swift`
    /// exists in more than one target and a filename key would let a clean
    /// one silently stand in for an offending one (#1207).
    private static let allowed = [
        "Cabalmail/Views/WarningTint.swift": 1,
        "Cabalmail/Views/FolderListView+Helpers.swift": 1,
        "Cabalmail/Views/AddressListView.swift": 1,
        "Cabalmail/Views/ToastBanner.swift": 1,
        "Cabalmail/Views/SignedInRootView.swift": 1,
        "Cabalmail/Views/FlagPaletteSettingsView.swift": 1,
    ]

    /// No source in the two targets that compile `WarningTint` may name the
    /// platform orange for itself.
    func testNoViewPinsThePlatformOrangeItself() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(
            sources.count, 40,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )
        // Per-target floor. The overall count is dominated by the iOS target,
        // so dropping the small one back out of the scan would not move it —
        // and a target outside the scan is how #1207 happened.
        for probe in ["Cabalmail/ContentView.swift", "CabalmailMac/CabalmailMacApp.swift"] {
            XCTAssertNotNil(sources[probe], "\(probe) is missing from the corpus")
        }

        var offenders: [String: Int] = [:]
        for (name, body) in sources {
            let hits = try Self.orangeHits(in: body)
            if hits > 0 { offenders[name] = hits }
        }

        XCTAssertEqual(
            offenders, Self.allowed,
            "a warning surface must ask WarningTint.tint(for:), not carry .orange itself (#1456)"
        )
    }

    /// Proves the detector catches the reported shape, on synthetic snippets
    /// rather than on the corpus — so a legitimate future rewrite of these
    /// views can't quietly make the test above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.orangeHits(in: ".foregroundStyle(.orange)"), 1)
        XCTAssertEqual(try Self.orangeHits(in: "        case .warn:  return .orange"), 1)
        XCTAssertEqual(try Self.orangeHits(in: ".tint(.orange)"), 1)
        XCTAssertEqual(
            try Self.orangeHits(in: ".foregroundStyle(WarningTint.tint(for: colorScheme).color)"),
            0
        )
        // The dynamic colour's own case name is not a use of it.
        XCTAssertEqual(try Self.orangeHits(in: "case .systemOrange: Color.orange"), 1)
        XCTAssertEqual(try Self.orangeHits(in: "WarningTint.tint(for: .light) == .systemOrange"), 0)
        // A mention in a comment cannot draw anything, and one of the sites
        // this suite guards carries exactly that (`ComposeView+Subviews`
        // explains why a plain `.orange` was wrong).
        XCTAssertEqual(try Self.orangeHits(in: "/// why a plain `.orange` didn't clear the floor"), 0)
        XCTAssertEqual(try Self.orangeHits(in: "Label(x) // was .orange\n.foregroundStyle(.orange)"), 1)
    }

    /// `force_try` is on in tests, so this throws rather than asserting the
    /// pattern compiles. Line comments are cut first: a doc comment naming
    /// the colour is a description of the rule, not a use of it.
    private static func orangeHits(in body: String) throws -> Int {
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        return try code.ranges(of: Regex(#"\.orange\b"#)).count
    }

    /// Every Swift source in the iOS/visionOS and macOS app targets, keyed by
    /// its path under `apple/`. Rooted off this file's own compile-time path
    /// so the scan follows the checkout wherever it lives.
    ///
    /// `CabalmailWatch` is deliberately outside this scan, and unlike the
    /// exemption #1207 refuted, this one is measured: watchOS draws these
    /// rows on black, where #1456 read the platform orange at 7.12:1 and
    /// 9.41:1, and the target does not compile `WarningTint` at all. If the
    /// watch ever gains a light surface, it needs the rule and this scan
    /// needs the target — the two go together.
    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["Cabalmail", "CabalmailMac"] {
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
