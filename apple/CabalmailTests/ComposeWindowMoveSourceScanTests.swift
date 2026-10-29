import XCTest

/// The two places "Open in New Window" reaches views no behaviour test can
/// host: the sheet's button, and the compose window that waits for the
/// draft. `ComposeWindowMoveTapTests` taps through the offer the router
/// makes (`ComposeWindowOffer.moving(with:along:)`, the only way to make
/// one), and `ComposeWindowMoveTests`' router double waits for the
/// snapshot as the window does; these pin that the button and the window
/// keep to it.
final class ComposeWindowMoveSourceScanTests: XCTestCase {

    /// The button opens the offer in its own action. A task there would ask
    /// for the window after the tap's turn, when iPadOS may leave it behind
    /// the main window and the move is refused.
    func testTheButtonOpensTheOfferInTheTapsOwnTurn() throws {
        let item = try Self.code(Self.source("CabalmailUI/Compose/ComposeWindowOfferItem.swift"))
        XCTAssertTrue(item.contains("Button { offer.open(model) } label: {"))
        XCTAssertNil(Self.deferral(in: item), "nothing may come between the tap and the move")
    }

    /// The window builds no composer while the hand-off awaits the sheet's
    /// snapshot. One built sooner starts from the seed, which carries only
    /// the draft's ID, declines the hand-off once in front, and every move
    /// is refused.
    func testTheWindowWaitsForTheDraftBeforeComposing() throws {
        let scene = try Self.code(Self.source("CabalmailUI/Compose/Windows/ComposeWindowScene.swift"))
        XCTAssertTrue(scene.contains(
            "appState.composeSlots.mayCompose(seed, closedOn: closedOn) { "
                + "if appState.compose.handoffs.awaitsSnapshot(for: seed.id) { awaitingDraft } "
                + "else { composeView(client: client) } }"
        ))
        XCTAssertEqual(scene.components(separatedBy: "composeView(client: client)").count - 1, 1)
        let built = try XCTUnwrap(scene.range(of: "ComposeView(model:"), "no composer is built in the window")
        let builder = try XCTUnwrap(scene.range(of: "func composeView(client: CabalmailClient)"))
        XCTAssertLessThan(builder.upperBound, built.lowerBound, "a composer built outside `composeView`")
        XCTAssertEqual(scene.components(separatedBy: "ComposeView(model:").count - 1, 1)
    }

    /// Proves the scans catch the shapes they exist for, so a change to
    /// `code(_:)` cannot quietly make them vacuous.
    func testTheScansCatchTheShapesTheyPin() {
        let deferred = Self.code("""
            Button {
                Task { offer.open(model) }
            } label: {
            """)
        XCTAssertFalse(deferred.contains("Button { offer.open(model) } label: {"))
        XCTAssertNotNil(Self.deferral(in: deferred))
        let eager = Self.code("""
            if let client = appState.client, appState.composeSlots.mayCompose(seed, closedOn: closedOn) {
                // Waits for nothing.
                composeView(client: client)
            }
            """)
        XCTAssertFalse(eager.contains("mayCompose(seed, closedOn: closedOn) { if appState.compose.handoffs"))
        XCTAssertEqual(
            Self.code("Button {\n    offer.open(model) // the tap\n} label: {"),
            "Button { offer.open(model) } label: {"
        )
    }

    /// A task, or an await, anywhere in `code`.
    private static func deferral(in code: String) -> Range<String.Index>? {
        code.range(of: #"\b(Task|await)\b"#, options: .regularExpression)
    }

    /// Line comments cut, then every run of whitespace made one space, so
    /// the scans read the code's shape rather than its layout.
    private static func code(_ body: String) -> String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
