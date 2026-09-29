import XCTest
@testable import Cabalmail

// Regression coverage for #901.
//
// The message list's rows each embedded a single-row `List` to borrow native
// `.swipeActions`, and SwiftUI scopes swipe mutual exclusivity to one `List`:
// N rows in N Lists have no shared state to retract each other, so several rows
// sat revealed at once and no gesture dismissed them. On 27 and later the fix
// is structural -- the row carries `.swipeActions` itself and the enclosing
// scroll view carries `.swipeActionsContainer()`, which owns the
// one-row-at-a-time bookkeeping -- with the embedded `List` kept below 27,
// where there is no container API and the deployment floor still reaches.
//
// The halves only work together: a row that has dropped its embedded `List`
// but sits in a scroll view WITHOUT the container still reveals and then never
// retracts anything at all (measured on the probe's `bare` arm), which is worse
// than the defect. Nothing in the type system connects them, so these scans do
// -- that is the pairing a future edit can silently break.
//
// The 27 path also has to hand `.swipeActions` nothing but `LiveSwipeButton`:
// outside a `List` SwiftUI keeps that content from the row's first build, and
// 1.22.2's version -- the spec's own button -- ran stale closures (#1747).
// `SwipeActionLiveContentTests` checks that behavior on the real container
// (macOS 27 and later); the scan below keeps the shape pinned on every runner.
final class SwipeActionContainerSourceScanTests: XCTestCase {

    /// The row wrapper and the one file that builds rows with it.
    private static let rowSource = "Cabalmail/Views/SwipeActionRow.swift"
    private static let listSource = "Cabalmail/Views/MessageListView+Selection.swift"

    /// The 27 path exists and is availability-gated, so the pre-27 floor keeps
    /// compiling. Both edges are wired on it: a path that revealed only one
    /// edge would read as the fix working.
    func testRowHasAnAvailabilityGatedContainerPath() throws {
        let code = Self.code(in: try Self.source(Self.rowSource))
        XCTAssertTrue(
            code.contains("#available(iOS 27.0, macOS 27.0, visionOS 27.0, *)"),
            "the container path is gated on 27 across all three platforms (#901)"
        )
        let container = try Self.slice(code, from: "private var containerRow: some View {")
        let edges = try Self.slice(code, from: "private func swipeEdges(")
        XCTAssertTrue(container.contains("swipeEdges("), "containerRow builds its edges through swipeEdges (#901)")
        for edge in ["trailing", "leading"] {
            XCTAssertTrue(
                edges.contains(".swipeActions(edge: .\(edge)) { LiveSwipeButton(edge: .\(edge)) }"),
                "the 27 path drops its \(edge) edge (#901)"
            )
        }
        XCTAssertFalse(
            container.contains("List {"),
            "the container path carries no embedded List -- that is the point (#901)"
        )
    }

    /// The 27 path's swipe content is `LiveSwipeButton` and nothing else, and
    /// the specs it reads are published OUTSIDE the `.swipeActions` modifiers
    /// (an environment value set inside them never reaches the revealed
    /// buttons). A button built from a spec here would be frozen at the row's
    /// first build -- the 1.22.2 regression (#1747).
    func testContainerSwipeContentHoldsNoRowData() throws {
        let code = Self.code(in: try Self.source(Self.rowSource))
        let edges = try Self.slice(code, from: "private func swipeEdges(")
        XCTAssertFalse(edges.contains("revealedButton"), "a spec's button inside .swipeActions freezes (#1747)")
        XCTAssertEqual(
            edges.components(separatedBy: "Button(").count,
            edges.components(separatedBy: "LiveSwipeButton(").count,
            "the only button the 27 path hands .swipeActions is LiveSwipeButton (#1747)"
        )
        let container = try Self.slice(code, from: "private var containerRow: some View {")
        guard let built = container.range(of: "swipeEdges("),
              let published = container.range(of: ".environment(\\.swipeActionSpecs") else {
            return XCTFail("containerRow must build swipeEdges and publish \\.swipeActionSpecs (#1747)")
        }
        XCTAssertLessThan(
            built.lowerBound, published.lowerBound,
            "the specs are published outside the .swipeActions modifiers, or they never reach the buttons (#1747)"
        )
    }

    /// The pre-27 path survives, both edges included: the floor is iOS 18 /
    /// macOS 15 and those builds still need a swipe, defect and all.
    func testEmbeddedListPathSurvivesForTheFloor() throws {
        let code = Self.code(in: try Self.source(Self.rowSource))
        let embedded = try Self.slice(code, from: "private var embeddedListRow: some View {")
        XCTAssertTrue(embedded.contains("List {"), "the pre-27 path still borrows a List (#901)")
        // Its row (and so its swipe actions) is a sibling declaration: the List
        // above holds `listRowContent`, which carries the `.listRow*` chrome the
        // borrowed List needs.
        let row = try Self.slice(code, from: "private var listRowContent: some View {")
        for edge in [".swipeActions(edge: .trailing)", ".swipeActions(edge: .leading)"] {
            XCTAssertTrue(row.contains(edge), "the pre-27 row drops \(edge) (#901)")
        }
        XCTAssertTrue(
            embedded.contains("listRowContent"),
            "the pre-27 List holds listRowContent, or the edges above are unreachable (#901)"
        )
    }

    /// The pairing: a file that builds `SwipeActionRow`s carries the container
    /// on its scroll view. Reverting just the modifier fails here.
    func testEverySwipeActionRowSiteCarriesTheContainer() throws {
        var offenders: [String] = []
        for path in try Self.rowCallSites() where
            !Self.code(in: try Self.source(path)).contains(".coordinatedSwipeActionsContainer()") {
            offenders.append(path)
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            "a SwipeActionRow needs a swipe-actions container above it (#901)"
        )
    }

    /// Inventory, not just offenders: a NEW file building rows shows up here
    /// rather than being silently exempt from the assertion above.
    func testRowCallSiteInventory() throws {
        XCTAssertEqual(try Self.rowCallSites(), [Self.listSource])
    }

    /// The gate is in the wrapper's own extension, so a call site cannot
    /// accidentally reach for the raw 27-only modifier and fail to build on the
    /// floor.
    func testCallSitesUseTheGatedWrapper() throws {
        let code = Self.code(in: try Self.source(Self.listSource))
        XCTAssertFalse(
            code.contains(".swipeActionsContainer()"),
            "call sites use coordinatedSwipeActionsContainer(), which is gated (#901)"
        )
        XCTAssertTrue(
            Self.code(in: try Self.source(Self.rowSource)).contains("swipeActionsContainer()"),
            "the gated wrapper is where the 27-only modifier is called (#901)"
        )
    }

    /// Both scanned files NAME the container and the wrapper in prose, so a
    /// scan that read comments would pass vacuously and a scan that read them
    /// as code would report the fixed file as an offender.
    func testTheScanReadsCodeNotProse() {
        let prose = "// carries `.swipeActionsContainer()` here"
        let doc = "    /// builds SwipeActionRow(\u{2026}) rows"
        let real = "  .coordinatedSwipeActionsContainer(), // 27+"
        XCTAssertFalse(Self.code(in: prose).contains("swipeActionsContainer()"))
        XCTAssertFalse(Self.code(in: doc).contains("SwipeActionRow("))
        XCTAssertTrue(Self.code(in: real).contains(".coordinatedSwipeActionsContainer()"))
        XCTAssertTrue(Self.code(in: "SwipeActionRow( // the wrapper").contains("SwipeActionRow("))
    }

    /// Floor: a mis-rooted scan reads every file as empty, and every assertion
    /// above that looks for an ABSENCE would pass.
    func testCorpusIsReadable() throws {
        XCTAssertTrue(try Self.source(Self.rowSource).contains("struct SwipeActionRow"))
        XCTAssertTrue(try Self.source(Self.listSource).contains("func virtualizedList"))
        XCTAssertFalse(try Self.rowCallSites().isEmpty, "no call sites found -- the scan is vacuous")
    }

    /// App sources (both app targets) that construct a `SwipeActionRow`, keyed
    /// by path: `ContentView.swift` exists in two targets, so filenames are not
    /// unique keys here.
    private static func rowCallSites() throws -> [String] {
        let roots = ["Cabalmail", "CabalmailMac"]
        var sites: [String] = []
        for root in roots {
            let base = apple.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let name as String in walker where name.hasSuffix(".swift") {
                let relative = "\(root)/\(name)"
                guard relative != rowSource else { continue }
                if code(in: try source(relative)).contains("SwipeActionRow(") {
                    sites.append(relative)
                }
            }
        }
        return sites.sorted()
    }

    /// The text of one declaration's body: from `opener` to the line that
    /// closes it at the declaration's own indentation. Used so an assertion
    /// about the 27 path can't be satisfied by the pre-27 path's text.
    private static func slice(_ body: String, from opener: String) throws -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else {
            throw XCTSkip("no declaration matching \(opener)")
        }
        let indent = lines[start].prefix { $0 == " " }
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" }) else {
            throw XCTSkip("unterminated declaration \(opener)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// `body` with line comments cut, so prose naming the container or the
    /// wrapper is not read as a use of either.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
