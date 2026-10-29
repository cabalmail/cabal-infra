import XCTest

/// The three places the compose sheet's lock reaches views no behaviour test
/// can host: the window's menus, the reader's hidden chord buttons, and the
/// sheet itself. While a window's compose sheet is up
/// (`SceneNavigator.composeLock`) nothing may archive, move or swap the
/// message behind it, and the sheet cannot be swiped away past the
/// keep-or-discard question. `WindowCommandsTests` and `DeepLinkRouterTests`
/// hold the rest (⌘⌫ and deep links) as behaviour.
final class ComposeSheetLockSourceScanTests: XCTestCase {

    /// The menus read no window, and dim, as they do with a compose window
    /// in front.
    func testTheMenusReadNoWindowWhileComposeIsUp() throws {
        let body = try Self.source("CabalmailUI/Shell/SignedInRootView.swift")
        XCTAssertTrue(body.contains(
            ".focusedSceneValue(\\.windowCommands, navigator.composeLock.isUp ? nil : windowCommands)"
        ))
        XCTAssertEqual(body.components(separatedBy: ".focusedSceneValue(\\.windowCommands").count - 1, 1)
    }

    /// The reader's hidden chords (⌘U, ⌘P, ⇧⌘M and the rest) go while compose
    /// is up: a key press in the composer would otherwise reach the message
    /// behind it.
    func testTheReadersChordsGoWhileComposeIsUp() throws {
        let body = try Self.source("CabalmailUI/Mail/Reader/MessageDetailView+ChordHosts.swift")
        XCTAssertTrue(body.contains("if let model, navigator?.composeLock.isUp != true {"))
    }

    /// The router publishes the flag, clears it through the navigator when
    /// the sheet has gone, and keeps the sheet from being swiped away.
    func testTheRouterLocksTheWindowAndTheSheet() throws {
        let body = try Self.source("CabalmailUI/Compose/Windows/ComposeRequestRouter.swift")
        XCTAssertTrue(body.contains("navigator.composeLock.isUp = isUp"))
        XCTAssertTrue(body.contains("navigator.composeClosed()"))
        XCTAssertTrue(body.contains(".interactiveDismissDisabled()"))
    }

    private static func source(_ path: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
