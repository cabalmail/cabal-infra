import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the feed rules' save tests share: a model over the scripted
/// `FakeRulesBackend`, the waits on its free-running saves, and a row that
/// holds one mail rule and one feed rule. A base class with no tests of its
/// own.
@MainActor
class FeedRulesSaveTestCase: XCTestCase {
    func makeModel(_ backend: FakeRulesBackend) -> RulesViewModel {
        let model = RulesViewModel(backend: backend)
        model.saveDebounce = .milliseconds(1)
        return model
    }

    /// Polls until the backend has recorded `count` saves (the debounce and
    /// the PUT run on free-running tasks, so assertions can't be time-fixed).
    func waitForSaves(
        _ backend: FakeRulesBackend, _ count: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 where backend.savedSets.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.savedSets.count, count, file: file, line: line)
    }

    /// Polls until the save has been answered and taken in.
    func waitForSaved(
        _ model: RulesViewModel, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 where model.saveState != .saved {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.saveState, .saved, file: file, line: line)
    }

    struct MissingSave: Error {}

    /// One save as the backend recorded it. `feedRules` is nil where the
    /// request carried no feed rules.
    struct RecordedSave {
        let rules: [Rule]
        let expectedVersion: Int
        let feedRules: [FeedRule]?
    }

    /// The `index`th save the backend recorded. A save that was never sent
    /// is a failure thrown here, not an index that traps: a trap ends the
    /// whole run and hides every test after it.
    func recordedSave(
        _ backend: FakeRulesBackend, _ index: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> RecordedSave {
        guard backend.savedSets.indices.contains(index),
              backend.savedFeedRules.indices.contains(index)
        else {
            XCTFail("save \(index) was never sent", file: file, line: line)
            throw MissingSave()
        }
        let save = backend.savedSets[index]
        return RecordedSave(
            rules: save.rules, expectedVersion: save.expectedVersion,
            feedRules: backend.savedFeedRules[index]
        )
    }

    func mailRule(name: String = "Receipts") -> Rule {
        Rule(
            name: name,
            conditions: [Rule.Condition(field: .subject, value: "invoice")],
            action: .move,
            moveFolder: "Receipts"
        )
    }

    /// The same rule for the same name, id included, so a list read back
    /// from the backend compares equal to the one that went in.
    func feedRule(name: String = "Releases") -> FeedRule {
        FeedRule(
            id: "r-" + String(format: "%012x", UInt64(bitPattern: Int64(name.hashValue)) % (1 << 48)),
            name: name,
            conditions: [
                FeedRule.Condition(field: .feed, value: "sub-1"),
                FeedRule.Condition(field: .title, value: "release"),
            ],
            flag: true
        )
    }

    /// A loaded model over a row that holds one mail rule and one feed rule.
    func loadedModel(_ backend: FakeRulesBackend) async -> RulesViewModel {
        backend.ruleSet = RuleSet(rules: [mailRule()], feedRules: [feedRule()], version: 5)
        let model = makeModel(backend)
        await model.load()
        return model
    }
}

/// The feed half of the Rules pane against the scripted `FakeRulesBackend`,
/// which treats the feed list as `/set_rules` does: a save that carries one
/// replaces the stored list, a save without one leaves it.
///
/// What these pin is when the feed list goes on the request. A mail-only
/// edit must send what a build from before feed rules sends (no `feedRules`
/// at all), and the stored list must come through it intact; a feed edit
/// must send both lists.
@MainActor
final class FeedRulesViewModelTests: FeedRulesSaveTestCase {
    // MARK: - Loading

    func testLoadPopulatesFeedRulesBesideMailRules() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        XCTAssertEqual(model.rules.map(\.name), ["Receipts"])
        XCTAssertEqual(model.feed.rules.map(\.name), ["Releases"])
        XCTAssertEqual(model.version, 5)
        // As loaded, the list is the server's: nothing to send.
        XCTAssertFalse(model.feed.hasUnsavedChanges)
    }

    func testLoadListsSubscriptionsByTitle() async throws {
        let backend = FakeRulesBackend()
        backend.subscriptions = [
            RssSubscription(subscriptionId: "sub-2", feedId: "f2", customTitle: "zebra"),
            RssSubscription(subscriptionId: "sub-1", feedId: "f1", customTitle: "Apple"),
        ]
        let model = await loadedModel(backend)
        XCTAssertEqual(model.feed.subscriptions.map(\.subscriptionId), ["sub-1", "sub-2"])
        XCTAssertEqual(model.feed.subscriptionTitle(for: "sub-2"), "zebra")
        XCTAssertNil(model.feed.subscriptionTitle(for: "gone"))
    }

    /// The picker's list is best effort, as the folder list is: without it
    /// the rules still load and edit.
    func testAFailedSubscriptionListDoesNotFailTheLoad() async throws {
        let backend = FakeRulesBackend()
        backend.subscriptionsError = CabalmailError.network("offline")
        let model = await loadedModel(backend)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.feed.rules.map(\.name), ["Releases"])
        XCTAssertEqual(model.feed.subscriptions, [])
    }

    // MARK: - When the feed list goes on the request

    func testAMailEditLeavesFeedRulesOffTheRequest() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 1)

        XCTAssertEqual(try recordedSave(backend, 0).rules.map(\.name), ["Invoices"])
        // Not an empty list, which would clear the stored one: no list.
        XCTAssertEqual(backend.savedFeedRules.count, 1)
        XCTAssertNil(try recordedSave(backend, 0).feedRules)
    }

    /// The acceptance the server half was checked for, from this side: a
    /// save that leaves `feedRules` out does not clear the stored list. The
    /// backend keeps what it holds, and the model keeps showing it, after
    /// the save and after a reload.
    func testASaveThatLeavesFeedRulesOutDoesNotClearTheStoredList() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertNil(try recordedSave(backend, 0).feedRules)
        XCTAssertEqual(backend.ruleSet.feedRules, [feedRule()])
        XCTAssertEqual(model.feed.rules, [feedRule()])
        XCTAssertFalse(model.feed.hasUnsavedChanges)

        backend.ruleSet.rules = try recordedSave(backend, 0).rules
        backend.ruleSet.version = model.version
        await model.load()
        XCTAssertEqual(model.feed.rules, [feedRule()])
    }

    func testAFeedEditSendsBothLists() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        model.feed.add(feedRule(name: "Security"))
        await waitForSaves(backend, 1)

        // `rules` is required by the server, so the mail rules ride along
        // unchanged.
        XCTAssertEqual(try recordedSave(backend, 0).rules.map(\.name), ["Receipts"])
        XCTAssertEqual(try recordedSave(backend, 0).expectedVersion, 5)
        XCTAssertEqual(try recordedSave(backend, 0).feedRules?.map(\.name), ["Releases", "Security"])
    }

    /// Once a feed save has landed the list is the server's again, so the
    /// next mail-only edit goes back to leaving it off.
    func testAfterAFeedSaveLandsAMailEditLeavesFeedRulesOffAgain() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        model.feed.add(feedRule(name: "Security"))
        await waitForSaves(backend, 1)
        await waitForSaved(model)
        XCTAssertFalse(model.feed.hasUnsavedChanges)

        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 2)
        XCTAssertNil(try recordedSave(backend, 1).feedRules)
        XCTAssertEqual(try recordedSave(backend, 1).expectedVersion, 6)
        // And the two feed rules are still there.
        XCTAssertEqual(backend.ruleSet.feedRules.map(\.name), ["Releases", "Security"])
    }

    /// Deleting the last feed rule has to reach the server as an empty
    /// list. Left off, the stored rule would come back on the next load.
    func testDeletingTheLastFeedRuleSendsAnEmptyList() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        model.feed.delete(id: try XCTUnwrap(model.feed.rules.first).id)
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertEqual(try recordedSave(backend, 0).feedRules, [])
        XCTAssertEqual(backend.ruleSet.feedRules, [])
        XCTAssertEqual(model.feed.rules, [])
    }

    /// A feed save that failed leaves the list unsaved, so whatever saves
    /// next, a mail edit included, carries it.
    func testAnUnsavedFeedEditRidesTheNextSave() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        backend.saveError = CabalmailError.network("offline")
        model.feed.add(feedRule(name: "Security"))
        await waitForSaves(backend, 1)
        for _ in 0..<200 where model.saveState == .saving || model.saveState == .idle {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.feed.hasUnsavedChanges)

        backend.saveError = nil
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 2)
        XCTAssertEqual(try recordedSave(backend, 1).feedRules?.map(\.name), ["Releases", "Security"])
    }

    // MARK: - Validation

    func testAnInvalidFeedRuleHoldsThePutAndSurfacesTheIssue() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        var rule = try XCTUnwrap(model.feed.rules.first)
        rule.name = ""
        model.feed.update(rule)
        for _ in 0..<200 where model.saveState == .idle {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            model.saveState, .error("Must be 1-100 characters, no control characters.")
        )
        XCTAssertEqual(backend.savedSets.count, 0)
    }

    /// A stored feed list this build would not have written (here, a rule
    /// with no name) is the server's own. It is not being sent, so it must
    /// not hold a mail save.
    func testAStoredFeedListIsNotJudgedWhenItIsNotSent() async throws {
        let backend = FakeRulesBackend()
        backend.ruleSet = RuleSet(
            rules: [mailRule()], feedRules: [feedRule(name: "")], version: 5
        )
        let model = makeModel(backend)
        await model.load()
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 1)
        await waitForSaved(model)
        XCTAssertNil(try recordedSave(backend, 0).feedRules)
    }
}

/// What the model does with the server's answer to a save that carried, or
/// left out, the feed rules: an edit made while it was out, a lost version
/// race, and a reply that could not be read.
@MainActor
final class FeedRulesSaveReplyTests: FeedRulesSaveTestCase {
    func testAFeedEditDuringAnInFlightSaveIsKeptAndSavedNext() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        backend.holdSaves = true
        model.feed.add(feedRule(name: "Security"))
        await waitForSaves(backend, 1)
        // The first PUT is out; edit again before it answers.
        model.feed.add(feedRule(name: "Outages"))
        backend.holdSaves = false
        backend.releaseHeldSaves()
        await waitForSaves(backend, 2)
        await waitForSaved(model)

        // The reply to the first save must not put the list back to what
        // that save sent.
        XCTAssertEqual(model.feed.rules.map(\.name), ["Releases", "Security", "Outages"])
        XCTAssertEqual(try recordedSave(backend, 1).feedRules?.map(\.name), ["Releases", "Security", "Outages"])
        XCTAssertEqual(try recordedSave(backend, 1).expectedVersion, 6)
    }

    /// One version guards both lists, so a feed edit that loses the race is
    /// the same conflict, and Reload takes the server's feed rules too.
    func testAConflictOnAFeedSaveReloadsBothLists() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        backend.saveError = RuleSetConflictError(serverVersion: 9)
        model.feed.add(feedRule(name: "Mine"))
        await waitForSaves(backend, 1)
        for _ in 0..<200 where !model.conflict {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.conflict)

        backend.saveError = nil
        backend.ruleSet = RuleSet(
            rules: [mailRule()], feedRules: [feedRule(name: "Theirs")], version: 9
        )
        await model.load()
        XCTAssertEqual(model.feed.rules.map(\.name), ["Theirs"])
        XCTAssertEqual(model.version, 9)
        XCTAssertFalse(model.feed.hasUnsavedChanges)
    }

    /// `/set_rules` commits before it answers, so a 200 whose body won't
    /// decode is a save that landed (#1903). The re-read takes in the feed
    /// rules the row now holds as well as the mail rules, and the list is
    /// then the server's: the next mail edit leaves it off the request.
    func testAnUnreadableSaveReplyTakesInTheServersFeedRules() async throws {
        let backend = FakeRulesBackend()
        let model = await loadedModel(backend)
        backend.saveError = CabalmailError.decoding("garbled")
        let added = feedRule(name: "Security")
        // What the server holds once it has committed the PUT whose reply
        // was lost, set before the edit because the re-read follows the
        // failed save at once.
        backend.ruleSet = RuleSet(
            rules: [mailRule()], feedRules: [feedRule(), added], version: 6
        )
        model.feed.add(added)
        await waitForSaves(backend, 1)
        await waitForSaved(model)
        XCTAssertEqual(model.version, 6)
        XCTAssertEqual(model.feed.rules.map(\.name), ["Releases", "Security"])
        XCTAssertFalse(model.feed.hasUnsavedChanges)

        backend.saveError = nil
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 2)
        XCTAssertNil(try recordedSave(backend, 1).feedRules)
        XCTAssertEqual(try recordedSave(backend, 1).expectedVersion, 6)
    }
}

/// A save's answer and the rows being edited. The editors draw a rule's
/// conditions by each one's local `id`, and a condition decoded from a
/// reply has a new one. So taking in an answer that changes nothing must
/// leave the local rules alone: replacing them with an equal copy rebuilt
/// the condition rows, and the field being typed in lost the keyboard
/// whenever the user paused long enough for a save to land. The backend
/// answers as the real client does here, with decoded values.
@MainActor
final class RulesSaveAnswerIdentityTests: FeedRulesSaveTestCase {
    func testAnUnchangedAnswerLeavesTheMailConditionBeingTypedIn() async throws {
        let backend = FakeRulesBackend()
        backend.answersAsDecoded = true
        let model = await loadedModel(backend)
        var edited = try XCTUnwrap(model.rules.first)
        edited.conditions[0].value = "invoices"
        model.update(edited)
        let typedIn = try XCTUnwrap(model.rules.first?.conditions.first?.id)
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertEqual(model.version, 6, "the answer was taken in")
        XCTAssertEqual(model.rules.first?.conditions.first?.id, typedIn)
    }

    func testAnUnchangedAnswerLeavesTheFeedConditionBeingTypedIn() async throws {
        let backend = FakeRulesBackend()
        backend.answersAsDecoded = true
        let model = await loadedModel(backend)
        var edited = try XCTUnwrap(model.feed.rules.first)
        edited.conditions[1].value = "releases"
        model.feed.update(edited)
        let typedIn = try XCTUnwrap(model.feed.rules.first?.conditions.last?.id)
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertEqual(model.version, 6, "the answer was taken in")
        XCTAssertEqual(model.feed.rules.first?.conditions.last?.id, typedIn)
        XCTAssertFalse(model.feed.hasUnsavedChanges)
    }

    /// A mail-only save answers the stored feed rules too, decoded. They
    /// are equal to the local ones, so they are left alone as well.
    func testAMailSaveLeavesTheFeedRulesRowsAlone() async throws {
        let backend = FakeRulesBackend()
        backend.answersAsDecoded = true
        let model = await loadedModel(backend)
        let feedCondition = try XCTUnwrap(model.feed.rules.first?.conditions.first?.id)
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertEqual(model.feed.rules.first?.conditions.first?.id, feedCondition)
    }

    /// The guard is on equality, not on adoption: when the server's set
    /// does differ (here it re-minted both rules' ids), it still replaces
    /// the local one.
    func testAnAnswerTheServerChangedStillReplacesBothLists() async throws {
        let backend = FakeRulesBackend()
        backend.answersAsDecoded = true
        backend.canonicalize = { sent in
            var answer = sent
            for index in answer.rules.indices { answer.rules[index].id = "r-00000000000\(index)" }
            for index in answer.feedRules.indices { answer.feedRules[index].id = "r-11111111111\(index)" }
            return answer
        }
        let model = await loadedModel(backend)
        var edited = try XCTUnwrap(model.rules.first)
        edited.name = "Invoices"
        model.update(edited)
        model.feed.add(feedRule(name: "Security"))
        await waitForSaves(backend, 1)
        await waitForSaved(model)

        XCTAssertEqual(model.rules.map(\.id), ["r-000000000000"])
        XCTAssertEqual(model.feed.rules.map(\.id), ["r-111111111110", "r-111111111111"])
        XCTAssertFalse(model.feed.hasUnsavedChanges)
    }
}
