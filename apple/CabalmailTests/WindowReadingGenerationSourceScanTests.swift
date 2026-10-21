import XCTest
@testable import CabalmailUI

// Regression coverage for #1981: the generation clause in
// `WindowReconciler.windowReading` -- the third of the five checks that issue
// names, and the second that no stand-down test can reach.
//
// A refresh pass compares the window's generation after each of its awaits and
// drops what it brought when a reset or a search moved it (#1870). The clause
// in `windowReading` cannot be isolated by a test, for two reasons that are
// both properties of `refreshPass`'s shape rather than gaps in the suite:
//
// - On the path that asks STATUS itself, the pass returns at its own guard the
//   line after that await, so it never reaches `windowReading` with a moved
//   generation. (That guard IS pinned:
//   `MessageListRefreshCharacterizationTests
//   .testAStatusAResetOvertookDoesNotOverwriteTheResetsCounts` fails when it
//   goes, which is what makes the other deletions mean something.)
// - On the path handed a STATUS already asked for, no await separates the
//   generation the pass captures from the `windowReading` call, so nothing can
//   interleave between them. The one await that could -- the cache invalidate
//   on a changed UIDVALIDITY -- carries its own guard and then re-captures the
//   generation the reset it runs moved.
//
// So the clause is belt and braces today, and deliberately kept: it is the
// check that would be load-bearing the moment an await appears ahead of it.
// Nothing in the type system says so, which is what this scan is for -- it
// fails when either reason stops holding, and a failure here is the signal
// that the stand-down test has become writable (and wanted).
final class WindowReadingGenerationSourceScanTests: XCTestCase {

    private static let refresherSource = "CabalmailUI/Mail/MessageList/WindowRefresher.swift"
    private static let reconcilerSource = "CabalmailUI/Mail/MessageList/WindowReconciler.swift"

    private static let capture = "var generation = window.alignment.generation"
    private static let recapture = "generation = window.alignment.generation"
    private static let guardLine = "guard generation == window.alignment.generation else { return }"
    private static let readingCall = "window.reconciler.windowReading("

    /// The asked path's own guard sits on the await's own heels, so a reset
    /// during the STATUS ends the pass there rather than at `windowReading`.
    func testTheAskedPathGuardsImmediatelyAfterTheStatusAwait() throws {
        let pass = try Self.refreshPass()
        let statusAwait = "status = try await window.client.folderStatus("
        let lines = Self.lines(pass)
        guard let asked = lines.firstIndex(where: { $0.contains(statusAwait) }) else {
            throw ScanAnchorMissing(description: "no STATUS await matching \(statusAwait)")
        }
        XCTAssertTrue(
            lines[(asked + 1)...].first?.contains(Self.guardLine) == true,
            "the pass guards the generation on the line after its STATUS await (#1981)"
        )
    }

    /// Between the generation the pass holds and the reading it is passed to,
    /// the only awaits are the two blocks that each guard the generation on
    /// their own heels -- the STATUS the pass asks for itself, and the cache
    /// invalidate on a changed UIDVALIDITY (which also re-captures). An await
    /// anywhere else in that span is a state the clause would have to catch.
    func testEveryAwaitAheadOfTheReadingGuardsTheGenerationItself() throws {
        let pass = try Self.refreshPass()
        let span = try Self.span(pass, from: Self.capture, to: Self.readingCall)
        let guarded = [try Self.statusChoice(pass), try Self.invalidateBranch(pass)]
        var rest = span
        for block in guarded {
            XCTAssertTrue(span.contains(block), "a guarded block moved out of the span (#1981)")
            rest = rest.replacingOccurrences(of: block, with: "")
        }
        XCTAssertFalse(
            rest.contains("await"),
            "an await here makes windowReading's generation clause load-bearing, "
                + "and a stand-down test for it writable (#1981)"
        )
    }

    /// The invalidate awaits are guarded, and the branch then takes a fresh
    /// generation, since the reset it runs moves the one the pass held.
    func testTheUidValidityBranchGuardsAndThenRecapturesTheGeneration() throws {
        let branch = try Self.invalidateBranch(try Self.refreshPass())
        XCTAssertTrue(branch.contains(Self.guardLine),
                      "the invalidate awaits are guarded before the reset runs (#1981)")
        let statements = Self.lines(branch).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "}" }
        XCTAssertEqual(
            statements.last, Self.recapture,
            "the branch leaves the pass holding the generation its own reset moved (#1981)"
        )
    }

    /// And the clause is still there to be belt and braces about.
    func testTheReadingStillCarriesTheGenerationClause() throws {
        let reading = try Self.slice(
            Self.code(in: try Self.source(Self.reconcilerSource)),
            from: "func windowReading("
        )
        XCTAssertTrue(reading.contains("generation == window.alignment.generation"),
                      "windowReading still compares the generation it was handed (#1981)")
    }

    // MARK: - Scanning

    private static func refreshPass() throws -> String {
        try slice(code(in: try source(refresherSource)), from: "private func refreshPass(prefetched:")
    }

    /// The `if let prefetched` / `else` pair that either takes the STATUS it
    /// was handed or asks for one, the latter guarded on the await's heels.
    private static func statusChoice(_ pass: String) throws -> String {
        try slice(pass, from: "if let prefetched {")
    }

    private static func invalidateBranch(_ pass: String) throws -> String {
        try slice(pass, from: "if let known = window.uidValidity, known != fresh {")
    }

    private static func lines(_ body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The text from the line holding `opener` through the line holding
    /// `closer`, both anchors required.
    private static func span(_ body: String, from opener: String, to closer: String) throws -> String {
        let lines = Self.lines(body)
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else {
            throw ScanAnchorMissing(description: "no line matching \(opener)")
        }
        guard let end = lines[start...].firstIndex(where: { $0.contains(closer) }) else {
            throw ScanAnchorMissing(description: "no line matching \(closer) after \(opener)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// The declaration `opener` starts, through the `}` at its own indent.
    private static func slice(_ body: String, from opener: String) throws -> String {
        let lines = Self.lines(body)
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else {
            throw ScanAnchorMissing(description: "no declaration matching \(opener)")
        }
        let indent = lines[start].prefix { $0 == " " }
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" }) else {
            throw ScanAnchorMissing(description: "unterminated declaration \(opener)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// `body` with line comments cut, so prose about an await is not read as
    /// one -- the comment this scan backs talks about awaits at length.
    private static func code(in body: String) -> String {
        Self.lines(body)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private struct ScanAnchorMissing: Error, CustomStringConvertible {
        let description: String
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
