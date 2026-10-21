import XCTest

/// The hole in this bundle's warnings-as-errors ratchet, covered where it
/// can be (#2135).
///
/// `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` on `CabalmailMacTests` (#1842) does
/// promote the grouped concurrency diagnostics — `sending`, the key-path
/// families — but not the actor-isolation ones, which were 178 of the 248
/// warnings that accumulated here, and `-swift-version 6` on this target
/// does not promote them either (both measured on #2135). They are emitted
/// as warnings whatever the build settings say, so no setting can keep them
/// from growing back.
///
/// What can: pinning the shape they almost all took. 165 of the 178 were a
/// `@MainActor` suite overriding `setUp`/`tearDown` synchronously and
/// touching its own isolated state from there — XCTest calls the
/// synchronous overrides from a nonisolated context, so every line in them
/// that reads an isolated property is a warning. The `async throws`
/// overrides run on the suite's actor and are warning-free, so the rule is
/// simply that an isolated suite's fixtures are `async throws`.
///
/// This is a scan, so it covers the shape rather than the diagnostic: a new
/// isolation warning of some other shape still lands silently, and the
/// `CabalmailiOSTests` bundle has the same hole with no scan of its own.
/// Both are named in #2135 rather than papered over here.
final class TestBundleIsolationScanTests: XCTestCase {
    /// The fixture overrides XCTest calls from a nonisolated context.
    private static let fixtures = ["setUp", "setUpWithError", "tearDown", "tearDownWithError"]

    func testIsolatedSuitesOverrideTheirFixturesAsynchronously() throws {
        var offenders: [String] = []
        var scanned = 0
        var isolated = 0
        for file in try Self.sources() {
            scanned += 1
            let code = Self.code(in: try String(contentsOf: file, encoding: .utf8))
            guard code.contains("@MainActor") else { continue }
            isolated += 1
            for fixture in Self.fixtures {
                for signature in Self.signatures(of: fixture, in: code) where !signature.contains("async") {
                    offenders.append("\(file.lastPathComponent): \(signature)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 250, "the scan found almost no sources, so it is not reading the bundle")
        XCTAssertGreaterThan(isolated, 150, "almost no suite read as isolated, so the @MainActor read is broken")
        XCTAssertEqual(
            offenders, [],
            """
            An isolated suite's fixtures run on its actor only when they are `async throws`; \
            a synchronous override is called from a nonisolated context, and every isolated \
            property it touches is a warning this bundle's ratchet cannot promote (#2135). \
            Offenders: \(offenders.joined(separator: ", "))
            """
        )
    }

    /// Each `override func <fixture>(` declaration's signature, up to its body.
    private static func signatures(of fixture: String, in code: String) -> [String] {
        var found: [String] = []
        var searched = code.startIndex..<code.endIndex
        while let declaration = code.range(of: "override func \(fixture)(", range: searched) {
            let body = code.range(of: "{", range: declaration.upperBound..<code.endIndex)
            found.append(String(code[declaration.lowerBound..<(body?.lowerBound ?? code.endIndex)]))
            searched = declaration.upperBound..<code.endIndex
        }
        return found
    }

    /// This bundle's sources: the scan lives among them.
    private static func sources() throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `body` with line comments cut, so a comment quoting a synchronous
    /// override — this file's own doc comment included — is not a finding.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }
}
