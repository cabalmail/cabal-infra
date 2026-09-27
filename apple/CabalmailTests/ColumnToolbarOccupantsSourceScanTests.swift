import XCTest

// Regression coverage for #1626.
//
// On iPadOS 27 the message-list column's navigation bar held five occupants —
// folder-panel toggle, Settings gear, the `INBOX` folder-switch title menu,
// Compose and Addresses — and overflowed a 378 pt bar. The two that folded
// into the system `OverflowBarButtonItem` were Compose and Addresses, and that
// item never presents on iPad: tapping it draws no menu, so both features were
// unreachable. With the addresses inspector open it was worse than that — the
// `@` toggle is the only control that closes the inspector, so folding it away
// left no exit but a relaunch (tester note on #1626, 2026-09-23).
//
// The human's call (2026-09-24) was to start by evicting the Settings gear and
// see whether four occupants fit. It has no unit seam — a `ToolbarItem` is not
// observable without a host and a real iPad bar — so this scan is what holds
// the eviction in place: Settings lives on the floating folder panel now, and
// the column's bar carries the folder toggle alone.
final class ColumnToolbarOccupantsSourceScanTests: XCTestCase {
    private static let path = "Cabalmail/Views/MailRootView.swift"

    /// The rule: nothing in the message-list column's toolbar block builds a
    /// gear. Re-adding one there re-creates the overflow this issue is about.
    func testTheColumnBarCarriesNoSettingsGear() throws {
        let block = try Self.code(in: Self.columnToolbarBlock())
        XCTAssertEqual(
            Self.gearHits(in: block), 0,
            "a fifth occupant in the column bar overflows it on iPadOS 27 (#1626)"
        )
        XCTAssertEqual(
            Self.settingsRequestHits(in: block), 0,
            "the Settings action moved to the folder panel (#1626)"
        )
    }

    /// The other half: it has to be somewhere. The folder panel is where it
    /// went, and a scan that only checked the bar would pass on a build that
    /// dropped Settings from the iPad entirely.
    func testTheFolderPanelCarriesTheSettingsGear() throws {
        let block = try Self.code(in: Self.folderPanelBlock())
        XCTAssertEqual(Self.gearHits(in: block), 1, "Settings has to be reachable on iPad (#1626)")
        XCTAssertEqual(Self.settingsRequestHits(in: block), 1)
    }

    /// The folder-panel toggle stays in the column bar: it is the only way to
    /// open the panel the gear now lives on, so evicting *it* would strand
    /// both (#1690).
    func testTheColumnBarKeepsTheFolderPanelToggle() throws {
        let block = try Self.code(in: Self.columnToolbarBlock())
        XCTAssertTrue(block.contains("sidebar.leading"))
        XCTAssertTrue(block.contains("folderPanelPresented.toggle()"))
    }

    /// The detectors on synthetic snippets, so a later rewrite of the view
    /// cannot make the assertions above vacuous.
    func testDetectorsCatchTheReportedShapes() {
        XCTAssertEqual(Self.gearHits(in: #"Image(systemName: "gearshape")"#), 1)
        XCTAssertEqual(Self.gearHits(in: #"Image(systemName: "gearshape.fill")"#), 1)
        XCTAssertEqual(Self.gearHits(in: #"Image(systemName: "sidebar.leading")"#), 0)
        XCTAssertEqual(Self.settingsRequestHits(in: "appState.requestSettings()"), 1)
        XCTAssertEqual(Self.settingsRequestHits(in: "appState.requestRefresh()"), 0)
    }

    /// A comment naming the gear is not a use of it — and the comment left in
    /// place of the evicted item names it twice.
    func testTheScanReadsCodeNotProse() {
        let reverted = """
        // The app-level Settings gear used to sit here: Image(systemName: "gearshape")
        // calling appState.requestSettings().
        ToolbarItem(placement: .topBarLeading) { folderToggle }
        """
        XCTAssertEqual(Self.gearHits(in: Self.code(in: reverted)), 0)
        XCTAssertEqual(Self.settingsRequestHits(in: Self.code(in: reverted)), 0)
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheBlocksAreReadable() throws {
        XCTAssertTrue(
            try Self.columnToolbarBlock().contains("showsSettingsGear"),
            "the column toolbar block did not load from \(Self.path)"
        )
        XCTAssertTrue(
            try Self.folderPanelBlock().contains("folderPanelWidth"),
            "the folder panel block did not load from \(Self.path)"
        )
    }

    // MARK: - Corpus

    private static func gearHits(in body: String) -> Int {
        matches(body, #"Image\(systemName:\s*"gearshape"#)
    }

    private static func settingsRequestHits(in body: String) -> Int {
        matches(body, #"requestSettings\(\)"#)
    }

    private static func matches(_ body: String, _ pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
    }

    /// The `showsSettingsGear` toolbar block — the message-list column's own
    /// bar on regular-width iPad — through the `#endif` that closes it.
    private static func columnToolbarBlock() throws -> String {
        try slice(from: "if showsSettingsGear {", to: "    /// Records the measured content-column width")
    }

    /// `folderPanelOverlay`'s body, through the end of its extension.
    private static func folderPanelBlock() throws -> String {
        try slice(from: "var folderPanelOverlay: some View {", to: "// MARK: - Resizable list column")
    }

    private static func slice(from start: String, to end: String) throws -> String {
        let source = try self.source()
        guard let lower = source.range(of: start), let upper = source.range(of: end) else {
            XCTFail("\(path) no longer contains the landmarks this scan reads")
            return ""
        }
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
