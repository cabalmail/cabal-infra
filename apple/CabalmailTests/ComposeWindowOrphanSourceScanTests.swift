import XCTest
@testable import Cabalmail

/// A compose window must always have a mail scene to land on when it
/// closes (#1688): iOS will not dismiss an app's last scene, and a compose
/// scene restored at launch can be the only one. Scenes cannot be
/// exercised in a unit test, so this pins the declaration. (Opting the
/// group out of restoration is not available on iOS; `SceneRestorationBehavior
/// .disabled` is macOS-only.)
final class ComposeWindowOrphanSourceScanTests: XCTestCase {

    func testClosingComposeAsksForAMailSceneWhenNoneIsRecorded() throws {
        let body = try Self.source("Cabalmail/Views/MainSceneActivation.swift")
        XCTAssertTrue(body.contains("UISceneSessionActivationRequest(role: .windowApplication)"))
        XCTAssertFalse(body.contains("guard let session else { return }"), "no silent no-op without a main scene")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
