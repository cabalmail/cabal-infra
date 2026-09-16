import XCTest

// Regression coverage for #1601.
//
// On macOS 27 the message list's folder-switch menu drew as a 36x36 circle
// holding only the pull-down chevron: the toolbar's default bordered style
// drops a `Menu`'s label, and the column's own title is removed on the
// assumption that the menu shows it, so the folder name appeared nowhere in
// the list column's chrome. The borderless button style lays the label out
// (`INBOX` plus the chevron, 62x16, measured in the app beside a stage build
// still drawing 36x36).
//
// There is no seam for a toolbar item's rendering, so this reads the source,
// in the shape the other `*SourceScanTests` set: the macOS menu carries both
// halves of the style, applied to the `Menu` itself (after its label, before
// its identifier), and neither half alone passes.
final class FolderSwitchMenuStyleSourceScanTests: XCTestCase {

    private static let path = "Cabalmail/Views/MessageListView+FolderSwitch.swift"

    func testTheMacMenuIsBorderless() throws {
        let menu = try Self.macMenu(in: Self.code(in: try Self.source()))
        XCTAssertTrue(
            Self.isBorderless(menu),
            "the folder-switch Menu needs .menuStyle(.button) + .buttonStyle(.borderless), "
                + "or macOS 27 draws no name (#1601)"
        )
    }

    /// The detector on synthetic snippets.
    func testDetectorNeedsBothHalvesOnTheMenu() {
        let label = "Menu {\n items\n} label: {\n Text(folder.name)\n}\n"
        let id = ".accessibilityIdentifier(\"list.folderSwitch\")"
        XCTAssertTrue(Self.isBorderless(label + ".menuStyle(.button)\n.buttonStyle(.borderless)\n" + id))
        XCTAssertFalse(Self.isBorderless(label + id), "the reported shape")
        XCTAssertFalse(Self.isBorderless(label + ".menuStyle(.button)\n" + id))
        XCTAssertFalse(Self.isBorderless(label + ".buttonStyle(.borderless)\n" + id))
        XCTAssertFalse(
            Self.isBorderless(label + id + "\n.menuStyle(.button)\n.buttonStyle(.borderless)"),
            "a style after the identifier is not on the menu this scan is about"
        )
    }

    func testTheScanReadsCodeNotProse() {
        XCTAssertFalse(Self.code(in: "// .menuStyle(.button)").contains(".menuStyle"))
    }

    /// Floor: a mis-rooted read or a moved menu finds nothing.
    func testTheMenuIsFound() throws {
        let menu = try Self.macMenu(in: Self.code(in: try Self.source()))
        XCTAssertTrue(menu.contains("Text(folder.name)"), "the menu's label is not in the slice")
    }

    // MARK: - Corpus

    /// From the macOS menu's declaration to its identifier.
    private static func macMenu(in code: String) throws -> String {
        let start = try XCTUnwrap(code.range(of: "var folderSwitchMenu: some View"), "\(path): menu not found")
        let end = try XCTUnwrap(
            code.range(of: #".accessibilityIdentifier("list.folderSwitch")"#, range: start.upperBound..<code.endIndex),
            "\(path): menu identifier not found"
        )
        return String(code[start.lowerBound..<end.upperBound])
    }

    /// Both style modifiers sit between the label and the identifier.
    private static func isBorderless(_ menu: String) -> Bool {
        guard let label = menu.range(of: "} label: {"),
              let id = menu.range(of: #".accessibilityIdentifier("list.folderSwitch")"#) else { return false }
        let modifiers = menu[label.upperBound..<id.lowerBound]
        return modifiers.contains(".menuStyle(.button)") && modifiers.contains(".buttonStyle(.borderless)")
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func source() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
