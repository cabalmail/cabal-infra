import XCTest
@testable import CabalmailUI

/// Pins the pairing behind #2016: every macOS reader toolbar slot's LIVE
/// control is the kind `ReaderToolbarLayout.macControlShape` says it is, and
/// the stand-ins are built from that policy rather than from a plain
/// `Button` each.
///
/// Nothing in the type system connects the two halves — the live controls
/// are eleven bespoke builders and the stand-ins are eleven greyed faces —
/// so the drift that produced the bug (a `Menu` grows a `primaryAction`, its
/// stand-in stays a button, the toolbar jumps) is exactly what a scan can
/// catch and a unit test cannot. Same template as
/// `ToolbarOverflowTitleSourceScanTests` beside it.
final class ReaderToolbarStandInShapeSourceScanTests: XCTestCase {

    /// Where each live macOS toolbar control is declared.
    private static let declarations: [ReaderToolbarAction: (file: String, name: String)] = [
        .reply: ("CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift", "replyButton"),
        .editDraft: ("CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift", "editDraftButton"),
        .remoteContent: ("CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift", "remoteContentButton"),
        .readerMode: ("CabalmailUI/Mail/Reader/MessageDetailView+Toolbar.swift", "readerModeButton"),
        .dispose: ("CabalmailUI/Mail/Reader/MessageDetailView+DisposeOptions.swift", "disposeButton"),
        .toggleRead: ("CabalmailUI/Mail/Reader/MessageDetailView+SeenOptions.swift", "seenButton"),
        .move: ("CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift", "moveButton"),
        .plainText: ("CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift", "plainTextButton"),
        .viewSource: ("CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift", "viewSourceButton"),
        .viewHeaders: ("CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift", "viewHeadersButton"),
        .printMessage: ("CabalmailUI/Mail/Reader/MessageDetailView+MacToolbar.swift", "printButton")
    ]

    func testEveryMacSlotHasADeclarationToRead() throws {
        // The inventory, asserted as well as the shapes: a twelfth slot in
        // `macToolbar` has to be added here or this fails by name rather
        // than quietly going unscanned.
        let drawn = Set(ReaderToolbarLayout.macToolbar(leading: .reply))
            .union(ReaderToolbarLayout.macToolbar(leading: .editDraft))
        XCTAssertEqual(
            drawn.subtracting(Set(Self.declarations.keys).union([.toggleFlag])).map(\.rawValue).sorted(),
            [],
            "a macOS toolbar slot with no declaration listed here"
        )
        XCTAssertEqual(Self.declarations.count, 11)
    }

    func testTheLiveControlsMatchThePolicy() throws {
        for (action, site) in Self.declarations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let body = try Self.declaration(named: site.name, in: site.file)
            let expected = ReaderToolbarLayout.macControlShape(for: action, flagMenuHasRows: false)
            XCTAssertEqual(
                Self.shape(ofDeclaration: body), expected,
                "\(site.name) draws a \(Self.shape(ofDeclaration: body)) where the policy says \(expected)"
            )
        }
    }

    func testTheFlagControlCarriesBothShapesThePolicyNames() throws {
        // The one slot whose shape is state-dependent: the empty-palette
        // branch is a plain button and the other is a split button, which is
        // what `macControlShape(for: .toggleFlag, flagMenuHasRows:)` answers.
        let body = try Self.declaration(
            named: "flagButton", in: "CabalmailUI/Mail/Reader/MessageDetailView+FlagOptions.swift"
        )
        XCTAssertTrue(body.contains("if rows.isEmpty {"), "the palette branch is what picks the shape")
        XCTAssertTrue(body.contains("primaryAction:"), "the non-empty branch is a split button")
        XCTAssertTrue(body.contains(".menuIndicator(optionMenuIndicator)"))
    }

    func testTheFeedsMoreMenuIsTheOnlyMenuOnTheWideBar() throws {
        let body = try Self.source("CabalmailUI/Feeds/Reader/FeedReaderToolbar.swift")
        // The macOS arm of the platform split, which is where the wide bar's
        // More menu is declared.
        guard let macArm = body.range(of: "    #else\n    /// macOS and visionOS: the link rows") else {
            throw AnchorGone.feedToolbarPlatformSplit
        }
        let tail = String(body[macArm.lowerBound...])
        XCTAssertTrue(tail.contains("Menu {"), "More is a menu on the wide bar")
        XCTAssertEqual(
            FeedReaderToolbarLayout.macControlShape(for: .more), .menu,
            "and the policy the stand-in reads says so"
        )
    }

    func testBothStandInSetsAreBuiltFromThePolicy() throws {
        let mail = try Self.source("CabalmailUI/Mail/Reader/EmptyDetailToolbar.swift")
        XCTAssertTrue(mail.contains("ReaderToolbarLayout.macControlShape("))
        XCTAssertTrue(mail.contains("ToolbarStandIn("))
        let feed = try Self.source("CabalmailUI/Feeds/Reader/EmptyFeedDetailToolbar.swift")
        XCTAssertTrue(feed.contains("FeedReaderToolbarLayout.macControlShape("))
        XCTAssertTrue(feed.contains("ToolbarStandIn("))
    }

    func testNeitherStandInSetBuildsEverySlotAsAPlainButton() throws {
        // The negative control, and the pre-fix spelling: both files used to
        // build every slot as `Button {} label: { … }.disabled(true)`, which
        // is what made the menu-shaped slots too narrow. A revert to it fails
        // here even if the assertions above were scanning the wrong thing.
        for path in [
            "CabalmailUI/Mail/Reader/EmptyDetailToolbar.swift",
            "CabalmailUI/Feeds/Reader/EmptyFeedDetailToolbar.swift"
        ] {
            let body = try Self.source(path)
            XCTAssertFalse(
                body.contains("Button {} label: {"),
                "\(path) builds a stand-in as a plain button directly"
            )
        }
    }

    func testTheShapeDetectorReadsTheThreeSpellings() {
        // Detector self-tests: what stops a later rewrite making the scan
        // vacuous. The snippets are the three shapes as this tree writes
        // them.
        XCTAssertEqual(Self.shape(ofDeclaration: """
            Button {
                act()
            } label: {
                Label("Move", systemImage: "folder")
            }
            """), .button)
        XCTAssertEqual(Self.shape(ofDeclaration: """
            Menu {
                Button("Reply") {}
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            """), .menu)
        XCTAssertEqual(Self.shape(ofDeclaration: """
            Menu {
                rows()
            } label: {
                face
            } primaryAction: {
                act()
            }
            .menuIndicator(optionMenuIndicator)
            """), .splitButton)
        // A comment naming the other shape must not reclassify a button, and
        // a `Menu` named in prose is not a menu.
        XCTAssertEqual(Self.shape(ofDeclaration: """
            // A Menu here would need a primaryAction:, which this isn't.
            Button {
                act()
            } label: {
                face
            }
            """), .button)
    }

    /// Which kind of control a declaration's body builds, read the way the
    /// policy states it: a `Menu` with a `primaryAction:` is a split button,
    /// a bare `Menu` is a pull-down, anything else is a plain button. `//`
    /// comments are stripped first — prose naming a shape is not a shape
    /// (#1548).
    private static func shape(ofDeclaration body: String) -> ReaderToolbarControlShape {
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
        guard code.range(of: #"\bMenu\s*\{"#, options: .regularExpression) != nil else {
            return .button
        }
        return code.contains("primaryAction:") ? .splitButton : .menu
    }

    /// The body of a `var <name>: some View { … }` declaration, sliced to the
    /// declaration rather than the file: these files hold a dozen builders
    /// each and a neighbour's `Menu` would answer for this one (#1734).
    private static func declaration(named name: String, in path: String) throws -> String {
        let body = try source(path)
        guard let start = body.range(of: "    var \(name): some View {") else {
            // A scan whose anchor is gone fails rather than passing on an
            // empty string: a rename must not turn this into a no-op.
            throw AnchorGone.declaration(name)
        }
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else {
            throw AnchorGone.declaration(name)
        }
        return String(rest[rest.startIndex..<end.lowerBound])
    }

    private enum AnchorGone: Error {
        /// A live toolbar control's declaration, which this scan classifies.
        case declaration(String)
        /// The `#if os(iOS)` / `#else` split around the feed bar's More menu.
        case feedToolbarPlatformSplit
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
