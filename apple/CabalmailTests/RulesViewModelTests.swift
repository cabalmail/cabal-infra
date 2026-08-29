import XCTest
import CabalmailKit
@testable import Cabalmail

/// `RulesViewModel` behavior against a scripted `RulesBackend`: load,
/// debounced whole-set saves, the validation gate, optimistic-concurrency
/// conflict handling, and the list mutations.
@MainActor
final class RulesViewModelTests: XCTestCase {
    private func makeModel(
        _ backend: FakeRulesBackend
    ) -> RulesViewModel {
        let model = RulesViewModel(backend: backend)
        model.saveDebounce = .milliseconds(1)
        return model
    }

    /// Polls until the backend has recorded `count` saves (the debounce +
    /// PUT run on free-running tasks, so assertions can't be time-fixed).
    private func waitForSaves(
        _ backend: FakeRulesBackend, _ count: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 where backend.savedSets.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.savedSets.count, count, file: file, line: line)
    }

    private func sampleRule(name: String = "Receipts") -> Rule {
        Rule(
            name: name,
            conditions: [Rule.Condition(field: .subject, value: "invoice")],
            action: .move,
            moveFolder: "Receipts"
        )
    }

    func testLoadPopulatesRulesVersionAndFolders() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 5)
        backend.folders = [
            Folder(path: "INBOX"),
            Folder(path: "Container", attributes: ["\\Noselect"]),
            Folder(path: "Receipts"),
        ]
        let model = makeModel(backend)
        await model.load()
        XCTAssertEqual(model.rules.map(\.name), ["Receipts"])
        XCTAssertEqual(model.version, 5)
        XCTAssertFalse(model.isLoading)
        // The view's `.task` skips a reload on a model that already loaded.
        XCTAssertTrue(model.hasAttemptedLoad)
        // \Noselect containers are not offerable destinations.
        XCTAssertFalse(model.folders.contains { $0.path == "Container" })
        XCTAssertTrue(model.folders.contains { $0.path == "Receipts" })
    }

    func testLoadNormalizesLegacyContinueShapes() async {
        // Stored move/archive + continue predates the gated editor and
        // compiles identically to copy; the editor renders and saves it as
        // Copy (truthful Continue, decision 2) without scheduling a save of
        // its own — the normalized form persists on the next edit.
        let backend = FakeRulesBackend()
        var legacyMove = sampleRule()
        legacyMove.continueToNext = true
        var legacyDelete = sampleRule(name: "Purge")
        legacyDelete.action = .delete
        legacyDelete.continueToNext = true
        backend.ruleSet = RuleSet(rules: [legacyMove, legacyDelete], version: 1)
        let model = makeModel(backend)
        await model.load()

        XCTAssertEqual(model.rules[0].action, .copy)
        XCTAssertEqual(model.rules[0].copyFolders, ["Receipts"])
        XCTAssertTrue(model.rules[0].continueToNext)
        XCTAssertEqual(model.rules[1].action, .delete)
        XCTAssertFalse(model.rules[1].continueToNext)
        // Render-only: no PUT until the user edits something.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.savedSets.count, 0)
    }

    func testUpdateSchedulesDebouncedWholeSetSave() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 5)
        let model = makeModel(backend)
        await model.load()

        var edited = model.rules[0]
        edited.name = "Receipts 2026"
        model.update(edited)
        await waitForSaves(backend, 1)
        XCTAssertEqual(backend.savedSets[0].rules.map(\.name), ["Receipts 2026"])
        XCTAssertEqual(backend.savedSets[0].expectedVersion, 5)
        // The response version becomes the next expectedVersion.
        XCTAssertEqual(model.version, 6)
        XCTAssertEqual(model.saveState, .saved)
    }

    func testRapidMutationsCoalesceIntoOneSave() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 1)
        let model = makeModel(backend)
        await model.load()
        model.saveDebounce = .milliseconds(50)

        model.add(sampleRule(name: "A"))
        model.add(sampleRule(name: "B"))
        model.move(from: IndexSet(integer: 2), to: 0)
        await waitForSaves(backend, 1)
        try? await Task.sleep(for: .milliseconds(120))
        // Still one PUT, carrying the final order.
        XCTAssertEqual(backend.savedSets.count, 1)
        XCTAssertEqual(backend.savedSets[0].rules.map(\.name), ["B", "Receipts", "A"])
    }

    func testInvalidSetHoldsThePutAndSurfacesTheIssue() async {
        let backend = FakeRulesBackend()
        let model = makeModel(backend)
        await model.load()

        var bad = sampleRule()
        bad.name = ""
        model.add(bad)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.savedSets.count, 0)
        guard case .error = model.saveState else {
            return XCTFail("expected .error, got \(model.saveState)")
        }
    }

    func testConflictFlipsFlagAndReloadAdoptsWinner() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 2)
        let model = makeModel(backend)
        await model.load()

        backend.saveError = RuleSetConflictError(serverVersion: 9)
        var edited = model.rules[0]
        edited.name = "Mine"
        model.update(edited)
        for _ in 0..<200 where !model.conflict {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.conflict)

        // Reload (the alert's only affordance) adopts the winning set.
        backend.ruleSet = RuleSet(rules: [sampleRule(name: "Theirs")], version: 9)
        await model.load()
        XCTAssertEqual(model.rules.map(\.name), ["Theirs"])
        XCTAssertEqual(model.version, 9)
    }

    /// UAT regression: a keystroke landing while a PUT is in flight must not
    /// cancel that request. The server commits a PUT whether or not the
    /// client hangs up, so an aborted request left `version` stale and the
    /// next save's 409 masqueraded as another device's edit ("only the A in
    /// Amazon was saved").
    func testMutationDuringInFlightSaveDoesNotCancelThePut() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 1)
        let model = makeModel(backend)
        await model.load()
        backend.holdSaves = true

        var edited = model.rules[0]
        edited.name = "A"
        model.update(edited)
        await waitForSaves(backend, 1)
        // Keystroke while PUT 1 is held in flight: before the fix this
        // cancelled the save task, the (cancellation-aware) backend threw,
        // and the committed version was never adopted.
        edited.name = "Amazon"
        model.update(edited)
        try? await Task.sleep(for: .milliseconds(50))
        backend.holdSaves = false
        backend.releaseHeldSaves()
        await waitForSaves(backend, 2)
        for _ in 0..<200 where model.version < 3 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // The follow-up save carries PUT 1's response version, not a stale
        // one, and no conflict is reported.
        XCTAssertEqual(backend.savedSets[1].expectedVersion, 2)
        XCTAssertEqual(backend.savedSets[1].rules.map(\.name), ["Amazon"])
        XCTAssertFalse(model.conflict)
        XCTAssertEqual(model.version, 3)
    }

    func testListMutations() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 1)
        let model = makeModel(backend)
        await model.load()

        let newID = model.add()
        XCTAssertEqual(model.rules.count, 2)
        XCTAssertEqual(model.rules.last?.id, newID)

        let copyID = model.duplicate(model.rules[0].id)
        XCTAssertEqual(model.rules.count, 3)
        XCTAssertEqual(model.rules[1].id, copyID)
        XCTAssertEqual(model.rules[1].name, "Receipts copy")
        XCTAssertNotEqual(model.rules[1].id, model.rules[0].id)

        model.setEnabled(model.rules[0].id, false)
        XCTAssertFalse(model.rules[0].enabled)

        model.delete(id: model.rules[0].id)
        XCTAssertEqual(model.rules.count, 2)
    }

    func testAddRefusesBeyondServerCap() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(
            rules: (0..<RulesValidator.maxRules).map { Rule(name: "r\($0)") },
            version: 1
        )
        let model = makeModel(backend)
        await model.load()
        XCTAssertNil(model.add())
        XCTAssertEqual(model.rules.count, RulesValidator.maxRules)
    }

    func testCreateArchiveFolderRefreshesAndReports() async {
        let backend = FakeRulesBackend()
        let model = makeModel(backend)
        await model.load()
        XCTAssertFalse(model.hasArchiveFolder)

        backend.createdFolderAppears = true
        let created = await model.createArchiveFolder()
        XCTAssertTrue(created)
        XCTAssertEqual(backend.createdFolders, ["Archive"])
        XCTAssertTrue(model.hasArchiveFolder)
    }
}

// MARK: - #1328: a cancelled load is not a load failure

/// The push-transition cancellation (#1328) and what the loader owes it: on
/// iPhone the pushed Rules destination is built, torn down and rebuilt during
/// the transition, cancelling the first `.task` mid-fetch while the `@State`
/// model survives. The cancelled attempt must leave nothing to paint and no
/// record of having tried, so the rebuilt view's `.task` takes the load over.
@MainActor
final class RulesLoadCancellationTests: XCTestCase {
    private func makeModel(_ backend: FakeRulesBackend) -> RulesViewModel {
        let model = RulesViewModel(backend: backend)
        model.saveDebounce = .milliseconds(1)
        return model
    }

    /// Starts a load, waits for the backend to park, then cancels it the way
    /// SwiftUI cancels a `.task` whose view went away.
    private func loadCancelledMidFetch(
        _ model: RulesViewModel, _ backend: FakeRulesBackend
    ) async {
        backend.holdFetches = true
        let load = Task { await model.load() }
        for _ in 0..<200 where backend.fetchCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        load.cancel()
        backend.releaseHeldFetches()
        _ = await load.value
    }

    private func sampleRule() -> Rule {
        Rule(
            name: "Receipts",
            conditions: [Rule.Condition(field: .subject, value: "invoice")],
            action: .move,
            moveFolder: "Receipts"
        )
    }

    func testCooperativeCancellationPaintsNoErrorAndRecordsNoAttempt() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 5)
        let model = makeModel(backend)
        await loadCancelledMidFetch(model, backend)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.hasAttemptedLoad)
        // Still loading, not empty: the rebuilt view shows the spinner rather
        // than "No rules yet" while its own `.task` picks the fetch up.
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.rules.isEmpty)
    }

    /// The shape production actually sees: `URLSessionHTTPTransport`
    /// normalizes the cancelled data task to `CabalmailError.network`, whose
    /// `localizedDescription` is the reported "Couldn't reach the server.
    /// cancelled." — so the cancellation has to be read off the Task, not off
    /// the error.
    func testCancellationNormalizedToANetworkErrorIsStillNotPainted() async {
        let backend = FakeRulesBackend()
        backend.heldFetchError = CabalmailError.network("cancelled")
        let model = makeModel(backend)
        await loadCancelledMidFetch(model, backend)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.hasAttemptedLoad)
    }

    func testTheNextLoadTakesOverAndPopulates() async {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(rules: [sampleRule()], version: 5)
        backend.folders = [Folder(path: "INBOX"), Folder(path: "Receipts")]
        let model = makeModel(backend)
        await loadCancelledMidFetch(model, backend)
        // What the rebuilt view's `.task` does, having seen no attempt.
        backend.holdFetches = false
        await model.load()
        XCTAssertEqual(model.rules.map(\.name), ["Receipts"])
        XCTAssertEqual(model.version, 5)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
    }

    /// Control: a failure that is not a cancellation is still the user's to
    /// see, and still ends the attempt — the fix must not swallow the error
    /// state the Retry button exists for.
    func testARealFailureIsStillPaintedAndEndsTheAttempt() async {
        let backend = FakeRulesBackend()
        backend.fetchError = CabalmailError.network("The request timed out.")
        let model = makeModel(backend)
        await model.load()
        XCTAssertEqual(
            model.loadError,
            "Couldn't load rules: Couldn't reach the server. The request timed out."
        )
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertFalse(model.isLoading)
    }
}

/// Scripted backend. `@unchecked Sendable`: the view model is MainActor-
/// bound and awaits every call, so access is serial in these tests.
private final class FakeRulesBackend: RulesBackend, @unchecked Sendable {
    var ruleSet = RuleSet()
    var folders: [Folder] = []
    var saveError: Error?
    var fetchError: Error?
    /// When true, `fetchRules` records the call then parks until
    /// `releaseHeldFetches`, and — like a URLSession data task whose owning
    /// Task was cancelled — fails instead of returning.
    var holdFetches = false
    /// How a released-while-cancelled fetch fails. `CancellationError` is the
    /// cooperative throw; `CabalmailError.network("cancelled")` is what
    /// `URLSessionHTTPTransport` actually normalizes a cancelled data task
    /// into, which is the shape production sees.
    var heldFetchError: Error = CancellationError()
    private var heldFetches: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchCount = 0
    var createdFolders: [String] = []
    /// When true, a created folder shows up in the next `listFolders`.
    var createdFolderAppears = false
    /// When true, `saveRules` records the save then parks until
    /// `releaseHeldSaves`, and — like URLSession — throws if its task was
    /// cancelled while parked (the "server committed, client hung up" case).
    var holdSaves = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []
    private(set) var savedSets: [(rules: [Rule], expectedVersion: Int)] = []

    func releaseHeldSaves() {
        heldSaves.forEach { $0.resume() }
        heldSaves.removeAll()
    }

    func releaseHeldFetches() {
        heldFetches.forEach { $0.resume() }
        heldFetches.removeAll()
    }

    func fetchRules() async throws -> RuleSet {
        fetchCount += 1
        if holdFetches {
            await withCheckedContinuation { heldFetches.append($0) }
            if Task.isCancelled { throw heldFetchError }
        }
        if let fetchError { throw fetchError }
        return ruleSet
    }

    func saveRules(_ rules: [Rule], expectedVersion: Int) async throws -> RuleSet {
        savedSets.append((rules, expectedVersion))
        if holdSaves {
            await withCheckedContinuation { heldSaves.append($0) }
            try Task.checkCancellation()
        }
        if let saveError { throw saveError }
        return RuleSet(rules: rules, version: expectedVersion + 1)
    }

    func listFolders() async throws -> [Folder] { folders }

    func createFolder(name: String, parent: String?) async throws {
        createdFolders.append(name)
        if createdFolderAppears {
            folders.append(Folder(path: name))
        }
    }
}
