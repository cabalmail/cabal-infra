import XCTest
@testable import CabalmailKit

/// The colour-token catalog and accessors under `Sources/CabalmailKit/Design`
/// are generated from `design/color-tokens.json` by
/// `scripts/generate-color-tokens.py`. These tests hold the tree to that
/// file: the first re-runs the generator in check mode, so a hand edit to a
/// colorset or a token change without a regeneration fails here; the second
/// confirms the catalog is packaged in the resource bundle at all. Plain
/// `swift build` copies an `.xcassets` into the bundle as-is (no actool), so
/// under `swift test` the colorsets are present as directories; Xcode-driven
/// app builds compile the same catalog to `Assets.car`, which is what makes
/// `ColorTokens.*` resolve per appearance in the apps. Either form passes;
/// a catalog missing from `Package.swift`'s resources fails.
final class ColorTokensDriftTests: XCTestCase {
    private static let repoRoot: URL = {
        // Tests/CabalmailKitTests/<file> -> CabalmailKit -> apple -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    /// Runs the generator in check mode. `Process` exists only on macOS, and
    /// the Kit suite also runs on the iOS and visionOS simulators in CI; the
    /// macOS leg and `scripts/tests/test_check_color_tokens.py` carry this
    /// check, so the other legs skip rather than lose the test.
    func testGeneratedCatalogMatchesTokenFile() throws {
        #if !os(macOS)
        throw XCTSkip("the generator is run from the macOS leg; Process is unavailable here")
        #else
        let generator = Self.repoRoot.appendingPathComponent("scripts/generate-color-tokens.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: generator.path), "generator missing at \(generator.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", generator.path, "--check"]
        process.currentDirectoryURL = Self.repoRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "generated colour tokens are out of date:\n\(text)")
        #endif
    }

    func testCatalogIsPackagedInResourceBundle() {
        let compiled = Bundle.module.url(forResource: "Assets", withExtension: "car")
        let raw = Bundle.module.url(forResource: "danger-fg", withExtension: "colorset",
                                    subdirectory: "ColorTokens.xcassets")
        XCTAssertTrue(compiled != nil || raw != nil,
                      "ColorTokens.xcassets is not in the CabalmailKit resource bundle; check Package.swift")
    }
}
