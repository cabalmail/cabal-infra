import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A scripted `FlaggedMailSource`: each request is recorded and answered
/// from a script keyed by what it asked for, and a request can be held
/// until the test lets it go.
actor ScriptedFlaggedMail: FlaggedMailSource {
    struct Call: Hashable, Sendable {
        let criterion: FlagCriterion
        let cursor: String?
    }

    private(set) var calls: [Call] = []
    private var script: [Call: Result<FlaggedMailPage, any Error>] = [:]
    private var holdArmed = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// What a request for `criterion` after `cursor` answers. An unscripted
    /// request answers an empty last page.
    func answer(_ criterion: FlagCriterion, after cursor: String? = nil, with page: FlaggedMailPage) {
        script[Call(criterion: criterion, cursor: cursor)] = .success(page)
    }

    func fail(_ criterion: FlagCriterion, after cursor: String? = nil) {
        script[Call(criterion: criterion, cursor: cursor)] = .failure(URLError(.notConnectedToInternet))
    }

    /// The next request waits until `release()`.
    func holdNext() { holdArmed = true }
    var isHolding: Bool { !held.isEmpty }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func page(matching criterion: FlagCriterion, after cursor: String?) async throws -> FlaggedMailPage {
        let call = Call(criterion: criterion, cursor: cursor)
        calls.append(call)
        if holdArmed {
            holdArmed = false
            await withCheckedContinuation { held.append($0) }
        }
        guard let result = script[call] else { return .empty }
        return try result.get()
    }
}

/// What the Flagged view's tests build on: a real feed store, a scripted
/// mail source, the fake IMAP client a message's writes go to, and a real
/// mail store for the events and the mutation service.
@MainActor
final class FlaggedFixture {
    static let later = FlagPalette.slots[0]

    let directory: URL
    let store: RssStore
    let rss = FakeRssClient()
    let imap = FakeImapClient()
    let source = ScriptedFlaggedMail()
    let mailStore = AppState().mailStore
    let preferences: Preferences
    let client: CabalmailClient

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flagged-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        client = try TestFixtures.makeClient(imap: imap)
        let subscription = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .all)
        try await store.upsertSubscription(subscription)
        // The catalog the model's feed sync reads back: the store's own.
        await rss.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeModel() -> FlaggedListViewModel {
        FlaggedListViewModel(
            client: client, preferences: preferences, mailStore: mailStore, source: source, store: store,
            engine: RssSyncEngine(client: rss, store: store)
        )
    }

    /// Adds a flag of the user's own to Settings > Flags.
    func addLaterFlag() {
        preferences.flagPalette = [FlagPaletteEntry(slot: Self.later, label: "Later", color: "blue")]
    }

    // MARK: Rows

    static func date(_ iso: String) -> Date {
        // swiftlint:disable:next force_try
        try! Date.ISO8601FormatStyle().parse(iso)
    }

    static func mail(
        _ uid: UInt32, _ sent: String, folder: String = "INBOX", flags: Set<Flag> = [.flagged]
    ) -> SearchedEnvelope {
        let sent = date(sent)
        return SearchedEnvelope(
            envelope: Envelope(uid: uid, date: sent, subject: "m\(uid)", from: [], flags: flags, internalDate: sent),
            folder: folder
        )
    }

    static func page(
        _ rows: [SearchedEnvelope], total: Int? = nil, next: String? = nil, truncated: Bool = false
    ) -> FlaggedMailPage {
        FlaggedMailPage(rows: rows, total: total ?? rows.count, nextCursor: next, truncated: truncated)
    }

    /// Puts a flagged feed item in the store.
    func addItem(_ key: String, _ published: String, favorite: Bool = true, flags: Set<String> = []) async throws {
        try await store.upsertItems([
            RssItem(feedId: "f", subscriptionId: "s", itemId: key, sortKey: key, title: key, publishedAt: published,
                    isFavorite: favorite, flags: flags),
        ])
    }

    /// Five flagged messages over three pages: two, two and one.
    func scriptThreePages() async {
        await source.answer(.any, with: Self.page(
            [Self.mail(9, "2026-03-07T10:00:00Z"), Self.mail(8, "2026-03-05T22:00:00Z")], total: 5, next: "p2"
        ))
        await source.answer(.any, after: "p2", with: Self.page(
            [Self.mail(7, "2026-03-05T08:00:00Z"), Self.mail(6, "2026-03-02T08:00:00Z")], total: 3, next: "p3"
        ))
        await source.answer(.any, after: "p3", with: Self.page(
            [Self.mail(5, "2026-02-20T08:00:00Z")], total: 1
        ))
    }

    // MARK: Reading the list

    /// The list's rows by name: `m<uid>` for a message, the sort key for a
    /// feed item.
    static func names(_ model: FlaggedListViewModel) -> [String] {
        model.page.rows.map { row in
            switch row {
            case .mail(let envelope, _): return "m\(envelope.uid)"
            case .feed(let item): return item.sortKey
            }
        }
    }

    /// Waits for the model's loads to settle on `names`.
    func expect(
        _ model: FlaggedListViewModel, shows names: [String], file: StaticString = #filePath, line: UInt = #line
    ) async {
        try? await waitUntilOnMainActor(file: file, line: line) {
            Self.names(model) == names && !model.mailLoading
        }
        XCTAssertEqual(Self.names(model), names, file: file, line: line)
    }
}
