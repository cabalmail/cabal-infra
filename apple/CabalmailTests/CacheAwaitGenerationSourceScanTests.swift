import XCTest
@testable import CabalmailUI

// Regression coverage for #1981: the two generation checks in
// `WindowRefresher` whose race is a *cache* await -- the last two of the five
// checks that issue names, and the two no stand-down test can reach.
//
// A refresh pass compares the window's generation after each of its awaits
// and drops what it brought when a reset or a search moved it (#1870). Two of
// those checks answer a reset that lands while a cache await is out: the one
// after the UIDVALIDITY invalidate, before the pass wipes the rows, and the
// one before `settleAnchor`, after `applyRefreshPage` has written the page's
// rows and then its caches.
//
// Neither can be isolated by a behaviour test, and the reason is the test
// world's seams rather than a gap in the suite: the hold vocabulary is
// `FakeImapClient.HeldCall`, IMAP calls only, while `ListPagingWorld` and
// `TestFixtures` build a real `EnvelopeCache`/`MessageBodyCache` on a temp
// directory. A reset arranged against the IMAP calls those spans do contain
// is caught by a *different*, already-pinned guard -- so a test driven that
// way would pass with these clauses deleted, which is the vacuous-test trap.
// Giving the caches a holdable double would mean protocols over two concrete
// public actors, in the Kit and not only in test support, for two guards that
// already work; that was declined on 2026-10-21 in favour of this scan.
//
// So both clauses are pinned by shape here. Each case below falls over when
// its guard is deleted, when the guard stops covering the awaits it is there
// for, or when an await it does not cover appears in the span -- and that
// last failure is the signal that a holdable seam has arrived and the
// stand-down tests have become writable (and wanted).
final class CacheAwaitGenerationSourceScanTests: XCTestCase {

    private static let refresherSource = "CabalmailUI/Mail/MessageList/WindowRefresher.swift"

    private static let guardLine = "guard generation == window.alignment.generation else { return }"
    private static let fetchGuardLine =
        "guard generation == window.alignment.generation, !window.hasTrimmedFront else { return }"
    private static let invalidateBranch = "if let known = window.uidValidity, known != fresh {"
    private static let pageFetch = "await window.client.imapClient.topEnvelopes("
    private static let pageApply = "await applyRefreshPage("
    private static let settleAnchor = "await window.reconciler.settleAnchor("

    // MARK: - The UIDVALIDITY invalidate

    /// The guard covers both invalidate awaits and nothing else: a third
    /// await in that span is a state it was never written for, and -- if it
    /// is one the fake can hold -- the seam this check has been waiting for.
    func testTheInvalidateGuardCoversBothCacheAwaitsAndNoOthers() throws {
        let branch = try Self.invalidateBranchBody()
        let span = try Self.span(branch, from: Self.invalidateBranch, to: Self.guardLine)
        let awaits = Self.lines(span).filter { $0.contains("await") }
        XCTAssertEqual(awaits.count, 2, "the invalidate guard covers two awaits (#1981): \(awaits)")
        XCTAssertTrue(awaits.first?.contains("envelopeCache.invalidate(") == true,
                      "the first await the guard covers is the envelope cache invalidate (#1981)")
        XCTAssertTrue(awaits.last?.contains("bodyCache.invalidate(") == true,
                      "the second await the guard covers is the body cache invalidate (#1981)")
    }

    /// And the wipe it protects runs on the guard's heels, so nothing can
    /// interleave between the check and the rows it licenses dropping.
    func testTheWipeFollowsTheInvalidateGuardWithNoAwaitBetween() throws {
        let branch = try Self.invalidateBranchBody()
        let span = try Self.span(branch, from: Self.guardLine, to: "window.resetWindow()")
        XCTAssertFalse(
            span.contains("await"),
            "an await between the guard and the wipe leaves the rows it drops unchecked (#1981)"
        )
        let statements = Self.statements(span)
        XCTAssertEqual(statements.dropFirst().first, "window.envelopes = []",
                       "the guard is the line before the wipe it licenses (#1981)")
    }

    // MARK: - The page's cache writes

    /// The page fetch -- the one await in `refreshWindow` the fake *can* hold
    /// -- is guarded before `applyRefreshPage` runs. That is what makes the
    /// `settleAnchor` guard unreachable by a held IMAP call, and what makes
    /// it something other than a repeat of this one.
    func testThePageFetchIsGuardedBeforeTheCacheWritesRun() throws {
        let body = try Self.refreshWindowBody()
        let span = try Self.span(body, from: Self.pageFetch, to: Self.pageApply)
        XCTAssertTrue(span.contains(Self.fetchGuardLine),
                      "the page fetch carries its own generation guard (#1981)")
        let guardIndex = try Self.index(of: Self.fetchGuardLine, in: span)
        let applyIndex = try Self.index(of: Self.pageApply, in: span)
        XCTAssertLessThan(guardIndex, applyIndex,
                          "the fetch's guard runs before the cache writes do (#1981)")
    }

    /// And the `settleAnchor` guard covers exactly the span the fetch's guard
    /// cannot: `applyRefreshPage`, whose rows land first and whose cache
    /// writes are what the window can be replaced underneath.
    func testTheSettleAnchorGuardCoversTheCacheWritesAndNothingElse() throws {
        let body = try Self.refreshWindowBody()
        let covered = try Self.span(body, from: Self.fetchGuardLine, to: Self.guardLine)
        let awaits = Self.lines(covered).filter { $0.contains("await") }
        XCTAssertEqual(awaits.count, 1, "the settleAnchor guard covers one await (#1981): \(awaits)")
        XCTAssertTrue(awaits.first?.contains(Self.pageApply) == true,
                      "the await it covers is the page apply and its cache writes (#1981)")
        let anchored = try Self.span(body, from: Self.guardLine, to: Self.settleAnchor)
        XCTAssertEqual(Self.statements(anchored).count, 2,
                       "the guard is the statement before settleAnchor (#1981)")
    }

    /// The cache writes are cache writes: every await `applyRefreshPage` runs
    /// after the rows land is a cache call, which is why the reset that
    /// reaches the guard above cannot be arranged at the fake. An await here
    /// that is not a cache call is the writable-test signal.
    func testThePageApplyAwaitsOnlyTheCachesAndOnlyAfterTheRowsLand() throws {
        let apply = try Self.declaration("private func applyRefreshPage(")
        let lines = Self.lines(apply)
        let caches = ["bodyCache.remove(", "envelopeCache.remove(", "envelopeCache.merge("]
        let awaits = lines.filter { $0.contains("await") }
        XCTAssertFalse(awaits.isEmpty, "the page apply still writes the caches (#1981)")
        for line in awaits {
            XCTAssertTrue(
                caches.contains { line.contains($0) },
                "an await the fake can hold makes the settleAnchor stand-down test writable (#1981): \(line)"
            )
        }
        let firstAwait = try Self.index(of: "await", in: apply)
        let merge = try Self.index(of: "window.mergeFetched(", in: apply)
        XCTAssertLessThan(merge, firstAwait,
                          "the rows land before any await, as the caller's guard assumes (#1981)")
    }

    // MARK: - Scanning

    private static func refreshWindowBody() throws -> String {
        try declaration("private func refreshWindow(")
    }

    private static func invalidateBranchBody() throws -> String {
        try slice(try declaration("private func refreshPass(prefetched:"), from: invalidateBranch)
    }

    private static func declaration(_ opener: String) throws -> String {
        try slice(code(in: try source(refresherSource)), from: opener)
    }

    private static func lines(_ body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The non-empty, non-brace lines of `body`, trimmed: what reads as a
    /// statement once the comments are already cut.
    private static func statements(_ body: String) -> [String] {
        lines(body).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "}" }
    }

    private static func index(of needle: String, in body: String) throws -> Int {
        guard let found = lines(body).firstIndex(where: { $0.contains(needle) }) else {
            throw ScanAnchorMissing(description: "no line matching \(needle)")
        }
        return found
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
    /// one -- the comments these scans back talk about awaits at length.
    private static func code(in body: String) -> String {
        lines(body)
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
