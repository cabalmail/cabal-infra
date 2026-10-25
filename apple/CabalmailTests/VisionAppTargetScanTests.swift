import XCTest

// The project-shape half of #1865. The defect was never in the sources: one
// app target served iOS and visionOS, so the watch / NSE / web-extension
// embeds had to be destination-filtered to iOS, and an embed phase that
// exists with every member filtered out puts the app wrapper DIRECTORY into
// the `CodeSign` task's input tree. The second signed xrsimulator build into
// one DerivedData then cycles (`CodeSign Cabalmail.app` -> `_CodeSignature`
// -> `node: Cabalmail.app/` -> `directoryTreeSignature` -> back), and the
// directory never heals.
//
// So the fix is a shape: a separate `CabalmailVision` target over the same
// sources with no embeds, and no `destinationFilters` left anywhere. Nothing
// in the app's behaviour encodes that, and the build it breaks is the signed
// *incremental* one, which CI never makes (fresh workspace, unsigned) — this
// scan is the only regression test the invariant can have.
//
// It pins the CI half too: `apple.yml`'s visionOS legs have to name the new
// scheme, or the project change lands green here and red there.
final class VisionAppTargetScanTests: XCTestCase {

    // MARK: - project.yml

    func testVisionAppIsItsOwnTargetOverTheSameSources() throws {
        let vision = try Self.targetBlock("CabalmailVision")
        XCTAssertTrue(
            vision.contains("supportedDestinations: [visionOS]"),
            "CabalmailVision must be the visionOS-only app target (#1865)"
        )
        XCTAssertTrue(vision.contains("type: application"), "CabalmailVision must be an app target")
        XCTAssertTrue(
            vision.contains("- path: Cabalmail"),
            "CabalmailVision compiles the same sources as the iOS app; a copy of them would drift"
        )

        let ios = try Self.targetBlock("Cabalmail")
        XCTAssertTrue(
            ios.contains("supportedDestinations: [iOS, iPadOS]"),
            "the iOS app target must not support visionOS: one target serving both is what cycles (#1865)"
        )
    }

    func testNeitherAppTargetEmbedsAnythingItCannotShip() throws {
        let vision = try Self.targetBlock("CabalmailVision")
        for embed in ["CabalmailWatch", "CabalmailNotificationService", "CabalmailWebExtension"] {
            XCTAssertFalse(
                Self.withoutComments(vision).contains("- target: \(embed)"),
                "an embed phase on the visionOS app is the defect's shape, even with no members (#1865)"
            )
        }
        // The iOS target keeps all three, now unfiltered — the filters only
        // existed because this target also built visionOS.
        let ios = try Self.targetBlock("Cabalmail")
        for embed in ["CabalmailWatch", "CabalmailNotificationService", "CabalmailWebExtension"] {
            XCTAssertTrue(ios.contains("- target: \(embed)"), "the iOS app still embeds \(embed)")
        }
        XCTAssertFalse(
            Self.withoutComments(try Self.projectSpec()).contains("destinationFilters"),
            "a destination-filtered embed is what put the app wrapper in CodeSign's inputs (#1865)"
        )
    }

    /// One App Store record and one App Store profile (listing iOS and xrOS)
    /// serve both targets, so these three have to agree byte for byte.
    func testTheTwoAppTargetsStayOneAppStoreApp() throws {
        let ios = try Self.targetBlock("Cabalmail")
        let vision = try Self.targetBlock("CabalmailVision")
        let shared = [
            "PRODUCT_BUNDLE_IDENTIFIER: com.cabalmail.Cabalmail",
            "CODE_SIGN_ENTITLEMENTS: Cabalmail/Cabalmail.entitlements",
            "PROVISIONING_PROFILE_SPECIFIER: \"$(IOS_APP_STORE_PROFILE_UUID)\"",
        ]
        let iosLines = Self.settingLines(ios)
        let visionLines = Self.settingLines(vision)
        for setting in shared {
            // Whole lines, not `contains`: `com.cabalmail.CabalmailVision`
            // has `com.cabalmail.Cabalmail` as a prefix, and a substring
            // check read that divergence as a match (measured).
            XCTAssertTrue(iosLines.contains(setting), "the iOS target lost `\(setting)`")
            XCTAssertTrue(visionLines.contains(setting), "the visionOS target must keep `\(setting)` (#1865)")
        }
        // Each target excludes the other's generated Info.plist from the
        // shared source folder: copied in as a resource it collides with the
        // target's own processed plist ("Multiple commands produce ...").
        XCTAssertTrue(ios.contains("- InfoVision.plist"), "the iOS target must exclude the visionOS plist")
        XCTAssertTrue(vision.contains("- Info.plist"), "the visionOS target must exclude the iOS plist")
    }

    // MARK: - apple.yml

    func testCIBuildsAndArchivesTheVisionScheme() throws {
        let workflow = try Self.appleWorkflow()
        XCTAssertFalse(
            workflow.contains("{\"scheme\":\"Cabalmail\",\"platform\":\"visionOS\""),
            "app-build's visionOS leg must not name the iOS scheme: it no longer builds for visionOS (#1865)"
        )
        XCTAssertEqual(
            workflow.components(separatedBy: "{\"scheme\":\"CabalmailVision\",\"platform\":\"visionOS\"").count - 1,
            2,
            "both app-build matrices (pull_request and push) must build the visionOS scheme"
        )
        let archive = try XCTUnwrap(
            workflow.range(of: "xcodebuild archive").map { workflow[$0.upperBound...] },
            "apple.yml is missing its archive step"
        )
        let invocation = try XCTUnwrap(
            archive.range(of: "-configuration").map { archive[..<$0.lowerBound] },
            "the archive invocation lost its -configuration flag"
        )
        XCTAssertTrue(
            invocation.contains("-scheme ${{ matrix.scheme }}"),
            "the archive step must take the scheme from the upload matrix, not hardcode the iOS one (#1865)"
        )
        XCTAssertTrue(workflow.contains("scheme: CabalmailVision"), "the visionOS upload leg must name its scheme")
    }

    // MARK: - Corpus

    /// A target's own block, from `  <name>:` to the next target at the same
    /// indentation. Non-vacuity is asserted on every read: a renamed or
    /// deleted target fails here rather than passing an empty `contains`.
    private static func targetBlock(_ name: String) throws -> String {
        let spec = try projectSpec()
        let lines = spec.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try XCTUnwrap(
            lines.firstIndex(of: "  \(name):"),
            "project.yml declares no `\(name)` target"
        )
        var end = lines.index(after: start)
        while end < lines.endIndex {
            let line = lines[end]
            if line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":") { break }
            end = lines.index(after: end)
        }
        let block = lines[lines.index(after: start)..<end].joined(separator: "\n")
        XCTAssertGreaterThan(
            block.count, 200,
            "floor: a one-line \(name) block would pass every absence check vacuously"
        )
        return block
    }

    /// Every settings line in a block, trimmed, as a set.
    private static func settingLines(_ yaml: String) -> Set<String> {
        Set(
            withoutComments(yaml)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }

    /// Line comments cut: a comment naming a platform or a target explains
    /// the split, it does not configure it.
    private static func withoutComments(_ yaml: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func projectSpec() throws -> String {
        try read("project.yml")
    }

    private static func appleWorkflow() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
            .deletingLastPathComponent()   // repo root
        let url = repo
            .appendingPathComponent(".github/workflows/apple.yml")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("app-build:"), "floor: apple.yml is missing its app-build job")
        return body
    }

    /// Rooted off this file's own compile-time path, so the scan follows the
    /// checkout wherever it lives.
    private static func read(_ relativeToApple: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(relativeToApple), encoding: .utf8)
    }
}
