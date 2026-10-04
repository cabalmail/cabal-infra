import XCTest
@testable import CabalmailKit

/// Regression coverage for #1761.
///
/// An `AsyncStream` termination handler is STORED on the continuation, and the
/// types here hold that continuation, so whatever the handler captures holds
/// them back. Writing `[weak self]` on a closure *inside* the handler does not
/// weaken the handler: forming a weak reference needs a strong one in the
/// enclosing scope, and that scope is the stored handler. Two sites in this
/// package were written that way, which is the shape Xcode 27 reports as
/// `#ImplicitStrongCapture`.
///
/// `MailboxWatcherTests` and `DebugLogStoreTests` measure the consequence on
/// the two types that had it — the object outliving its last owner. This scan
/// is what keeps a NEW stream site from bringing the shape back: nothing in
/// the type system connects a capture list to the closure that stores it.
final class AsyncStreamTerminationCaptureScanTests: XCTestCase {

    /// How a site's termination handler treats `self`, read off its own
    /// capture list rather than off any closure nested inside it.
    private enum SelfCapture: String {
        /// The handler's own capture list weakens `self` — the fixed shape.
        case weakHandler
        /// The handler holds `self` strongly, deliberately: removal is
        /// synchronous under a lock, so there is no `Task` to weaken, and the
        /// handler (with its strong `self`) lives only as long as the stream
        /// it belongs to. `Reachability` is per-client, `SessionInvalidation`
        /// `Monitor` is one per `AppState`; both outlive their subscribers.
        case strongHandler
        /// The handler never mentions `self` — it cancels a captured `Task`.
        case noSelf
        /// The defect: a `[weak self]` deferred to a closure nested inside a
        /// handler that therefore captures `self` strongly anyway.
        case nestedWeak
    }

    /// Every `onTermination` site in the package, with the capture each one is
    /// expected to carry. Asserted as an INVENTORY, so a new stream site shows
    /// up here rather than being silently exempt from the offender check.
    private static let expected: [String: SelfCapture] = [
        "Auth/SessionInvalidationMonitor.swift": .strongHandler,
        "Cache/EnvelopeCache.swift": .weakHandler,
        "IMAP/ApiBackedImapClient.swift": .noSelf,
        "IMAP/MailboxWatcher.swift": .weakHandler,
        "Logging/DebugLogStore.swift": .weakHandler,
        "Outbox/Outbox.swift": .weakHandler,
        "Reachability.swift": .strongHandler,
    ]

    /// The rule, stated over the whole package: no stored handler defers its
    /// weak capture to a closure nested inside it.
    func testNoTerminationHandlerDefersItsWeakCaptureToANestedClosure() throws {
        let offenders = try Self.sites()
            .filter { $0.capture == .nestedWeak }
            .map(\.path)
            .sorted()
        XCTAssertEqual(
            offenders, [],
            "a [weak self] inside a stored termination handler does not weaken the handler (#1761)"
        )
    }

    /// Inventory: the set of sites and how each captures `self`. A new
    /// `onTermination` lands here as a failure naming its file.
    func testTerminationHandlerInventory() throws {
        let found = try Self.sites().reduce(into: [String: String]()) { map, site in
            map[site.path] = site.capture.rawValue
        }
        XCTAssertEqual(found, Self.expected.mapValues(\.rawValue))
    }

    /// The two types whose handler was rewritten carry the weak capture on the
    /// handler itself, and no longer on the `Task` inside it. Reverting either
    /// file fails here by name, with the rest of the scan green.
    func testTheTwoRewrittenSitesWeakenTheHandlerItself() throws {
        for path in ["IMAP/MailboxWatcher.swift", "Logging/DebugLogStore.swift"] {
            let handler = try XCTUnwrap(
                try Self.sites().first { $0.path == path },
                "no termination handler found in \(path)"
            )
            XCTAssertEqual(handler.capture, .weakHandler, "\(path) no longer weakens its handler (#1761)")
            XCTAssertTrue(
                handler.header.contains("@Sendable [weak self]"),
                "\(path)'s handler keeps its @Sendable attribute alongside the capture (#1761)"
            )
        }
    }

    /// Detector self-tests. Without these a later rewrite could make every
    /// assertion above vacuous and nothing would say so.
    func testClassifierReadsTheShapes() {
        let cases: [Shape] = [
            Shape("{ @Sendable [weak self] _ in", "Task { await self?.stop() }", .weakHandler),
            Shape("{ @Sendable _ in", "Task { [weak self] in await self?.stop() }", .nestedWeak),
            Shape("{ [weak self] _ in", "guard let self else { return }", .weakHandler),
            Shape("{ @Sendable _ in", "self.removeContinuation(id: id)", .strongHandler),
            Shape("{ _ in", "task.cancel()", .noSelf)
        ]
        for one in cases {
            XCTAssertEqual(
                Self.classify(header: one.header, body: one.body), one.expected,
                "misread \(one.header) / \(one.body)"
            )
        }
    }

    /// Comments are cut before anything is classified. Both rewritten files
    /// explain the rule in prose right above the handler, so a comment-blind
    /// scan would read a deliberately-strong handler as an offender and a
    /// fixed one as still carrying the nested capture.
    func testTheScanReadsCodeNotProse() throws {
        let strongWithProse = """
            continuation.onTermination = { @Sendable _ in
                // no [weak self] here: removal is synchronous under the lock
                self.removeContinuation(id: id)
            }
            """
        XCTAssertEqual(
            try Self.sites(in: Self.code(in: strongWithProse), path: "synthetic").map(\.capture),
            [.strongHandler],
            "prose naming a weak capture is not a weak capture"
        )
        XCTAssertEqual(
            try Self.sites(in: strongWithProse, path: "synthetic").map(\.capture),
            [.nestedWeak],
            "without the comment strip that same handler reads as an offender — which is what the strip is for"
        )
        let fixedWithProse = """
            continuation.onTermination = { @Sendable [weak self] _ in
                // a [weak self] on the Task inside here would not weaken this
                Task { await self?.stop() }
            }
            """
        XCTAssertEqual(
            try Self.sites(in: Self.code(in: fixedWithProse), path: "synthetic").map(\.capture),
            [.weakHandler]
        )
    }

    /// Floor: a mis-rooted scan reads every file as empty, and both the
    /// offender assertion and the "no nested weak" reading would pass.
    func testCorpusIsReadable() throws {
        let sites = try Self.sites()
        XCTAssertGreaterThanOrEqual(sites.count, 7, "the scan found almost no stream sites — it is vacuous")
        XCTAssertEqual(sites.count, Set(sites.map(\.path)).count, "one site per file is assumed by the inventory")
        XCTAssertTrue(try Self.source("IMAP/MailboxWatcher.swift").contains("public actor MailboxWatcher"))
    }

    // MARK: - Scanner

    /// One synthetic handler for the classifier self-tests above.
    private struct Shape {
        let header: String
        let body: String
        let expected: SelfCapture

        init(_ header: String, _ body: String, _ expected: SelfCapture) {
            self.header = header
            self.body = body
            self.expected = expected
        }
    }

    private struct Site {
        let path: String
        let header: String
        let capture: SelfCapture
    }

    /// Every `.swift` file under `Sources/CabalmailKit` that assigns an
    /// `onTermination` handler, keyed by its path below that root.
    private static func sites() throws -> [Site] {
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }
        var found: [Site] = []
        for case let name as String in walker where name.hasSuffix(".swift") {
            found += try sites(in: code(in: try source(name)), path: name)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The handlers in one already-comment-stripped file. The closure body is
    /// walked by BRACE DEPTH: a `{ ... }` regex stops at the first `}`, which
    /// here is the nested `Task`'s and hides the very shape being looked for.
    private static func sites(in code: String, path: String) throws -> [Site] {
        var found: [Site] = []
        var search = code.startIndex..<code.endIndex
        while let assign = code.range(of: "onTermination = {", range: search) {
            var depth = 0
            var end = assign.upperBound
            var index = code.index(before: assign.upperBound)  // the opening brace
            while index < code.endIndex {
                if code[index] == "{" { depth += 1 }
                if code[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = code.index(after: index)
            }
            let closure = String(code[code.index(before: assign.upperBound)...end])
            let split = closure.range(of: " in") ?? closure.startIndex..<closure.startIndex
            let header = String(closure[closure.startIndex..<split.upperBound])
            let body = String(closure[split.upperBound...])
            found.append(Site(path: path, header: header, capture: classify(header: header, body: body)))
            search = end..<code.endIndex
        }
        return found
    }

    private static func classify(header: String, body: String) -> SelfCapture {
        if header.contains("[weak self]") { return .weakHandler }
        if body.contains("[weak self]") { return .nestedWeak }
        return body.contains("self") ? .strongHandler : .noSelf
    }

    /// `body` with line comments cut, so prose naming a capture list is not
    /// read as one.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CabalmailKit
        .appendingPathComponent("Sources/CabalmailKit")

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
