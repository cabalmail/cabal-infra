import XCTest

// Regression coverage for #1578.
//
// #1547 routed the watch's revoke/suspend confirmations and its large-type
// detail through `AddressDisplay.wrappable`, and left two surfaces in the same
// target drawing the address raw: the address list rows and the new-address
// preview. Both wrap on a watch face, and watchOS hyphenates the unbreakable
// token when they do, so the list drew `q3v8t1zr@p9c5d7ka.ca-` / `balmail.com`
// and the preview `8ha6ecpg@vy3z4a8i.-` / `cabalmail.com` — addresses that
// don't exist.
//
// `CabalmailWatch` has no test bundle, so these read its sources. The rule is
// "an address drawn in a watch `Text` goes through `wrappable`", and a raw
// `Text(address.address)` coming back is the failure the report took.
//
// The iOS/macOS address rows are outside this scan on purpose: they are not
// measured to hyphenate, and a scan asserting a rule nobody has shown applies
// there would be a claim, not a test.
final class WatchAddressWrapSourceScanTests: XCTestCase {

    /// The two sites #1578 fixed, each asked for by name so a rewrite that
    /// drops the treatment fails here rather than only on a watch face.
    func testTheListRowAndThePreviewDrawTheWrappableAddress() throws {
        let sources = try Self.watchSources()
        let expected = [
            "CabalmailWatch/ContentView.swift": "Text(AddressDisplay.wrappable(address.address))",
            "CabalmailWatch/NewAddressView.swift": "Text(AddressDisplay.wrappable(preview))",
        ]
        for (path, call) in expected {
            let body = try XCTUnwrap(sources[path], "\(path) is missing from the corpus")
            XCTAssertTrue(
                Self.code(in: body).contains(call),
                "\(path): draw the address through AddressDisplay.wrappable (#1578)"
            )
        }
    }

    func testNoWatchTextDrawsARawAddress() throws {
        var offenders: [String: Int] = [:]
        for (path, body) in try Self.watchSources() {
            let hits = try Self.rawAddressHits(in: Self.code(in: body))
            if hits > 0 { offenders[path] = hits }
        }
        XCTAssertEqual(
            offenders, [:],
            "a raw address in a watch Text hyphenates when it wraps (#1578)"
        )
    }

    /// The detector on synthetic snippets, so a later rewrite of the views
    /// can't make the scan above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.address)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text( address )"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(preview)\n    .font(.caption2)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(AddressDisplay.wrappable(address.address))"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(AddressDisplay.wrappable(preview))"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.comment ?? \"\")"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "LargeTypeAddress(address: address.address)"), 0)
    }

    /// A comment explaining the rule names the raw call, and is not one.
    func testTheScanReadsCodeNotProse() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: Self.code(in: "/// used to be Text(address.address)")), 0)
        XCTAssertEqual(
            try Self.rawAddressHits(in: Self.code(in: "Text(address.address) // the old row")),
            1
        )
    }

    /// Floor: a mis-rooted walk reads nothing and passes everything above.
    func testCorpusIsReadable() throws {
        let sources = try Self.watchSources()
        XCTAssertGreaterThanOrEqual(sources.count, 5, "the watch target did not load")
        XCTAssertTrue(
            sources["CabalmailWatch/AddressDetailView.swift"]?.contains("AddressDisplay.wrappable") == true,
            "the detail view — the treatment's first watch site — is missing from the corpus"
        )
    }

    // MARK: - Corpus

    /// `Text(address)`, `Text(<anything>.address)` or `Text(preview)`: the
    /// expressions the watch views hold a whole address in.
    private static func rawAddressHits(in body: String) throws -> Int {
        try body.ranges(of: Regex(#"\bText\(\s*(?:(?:\w+\.)*address|preview)\s*\)"#)).count
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    /// Every Swift source in the watch target, keyed by its path under
    /// `apple/` — `ContentView.swift` also exists in the iOS target.
    private static func watchSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        let root = apple.appendingPathComponent("CabalmailWatch")
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
