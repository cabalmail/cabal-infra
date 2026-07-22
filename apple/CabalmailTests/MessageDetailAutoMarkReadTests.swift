import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #735: the `.afterDelay` auto-mark-as-read
// path was silently dropped on iPhone because SwiftUI fires phantom
// `.onDisappear` calls mid-push for view instances that aren't actually
// going away (same root cause as #403). The old `onDisappear` cancelled
// `pendingMarkAsReadTask` every time, killing the 2-second delayed STORE
// before it could fire. These tests pin the fixed behavior:
//
// - `onDisappear` must NOT cancel a pending mark-as-read task.
// - Manually toggling seen and disposing the message still cancel it —
//   those are legitimate supersessions and were already correct.
@MainActor
final class MessageDetailAutoMarkReadTests: XCTestCase {

    private func makePreferences(markAsRead: MarkAsReadBehavior) -> Preferences {
        // Preferences.init only writes pure defaults; the stored value is
        // pulled in by `activate(...)`, which the app calls once auth
        // resolves the account scope. Without it the store is dormant and
        // the scheduler always sees `.manual`.
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "tester")
        preferences.markAsRead = markAsRead
        return preferences
    }

    private func makeModel(
        markAsRead: MarkAsReadBehavior,
        flags: Set<Flag> = []
    ) throws -> MessageDetailViewModel {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let folder = Folder(path: "INBOX", attributes: [], isSubscribed: true)
        let envelope = TestFixtures.makeEnvelope(uid: 42, flags: flags)
        return MessageDetailViewModel(
            folder: folder,
            envelope: envelope,
            client: client,
            preferences: makePreferences(markAsRead: markAsRead)
        )
    }

    // MARK: - Regression: phantom onDisappear must not cancel the pending task

    func testOnDisappearDoesNotCancelPendingMarkAsReadTask() throws {
        // The tester's exact scenario: body load succeeds, scheduler spawns
        // the 2-second task, iPhone fires a phantom `.onDisappear` while
        // the user is still reading. Before #735 the task was cancelled
        // here and the STORE never happened.
        let model = try makeModel(markAsRead: .afterDelay)

        model.scheduleMarkAsReadIfNeeded()

        let scheduled = try XCTUnwrap(model.pendingMarkAsReadTask)
        XCTAssertFalse(scheduled.isCancelled)

        model.onDisappear()

        XCTAssertNotNil(model.pendingMarkAsReadTask, "the task reference must survive onDisappear")
        XCTAssertFalse(
            model.pendingMarkAsReadTask?.isCancelled ?? true,
            "phantom onDisappear must not cancel the pending mark-as-read task"
        )

        // Prevent a lingering 2s Sleep from bleeding into the next test.
        model.pendingMarkAsReadTask?.cancel()
    }

    func testManualToggleSeenStillCancelsPendingTask() async throws {
        // The setSeen path is a legitimate supersession — the user manually
        // marked the message read (or the dispose path did) so the delayed
        // write is redundant. That cancellation must still happen.
        let model = try makeModel(markAsRead: .afterDelay)

        model.scheduleMarkAsReadIfNeeded()
        let scheduled = try XCTUnwrap(model.pendingMarkAsReadTask)
        XCTAssertFalse(scheduled.isCancelled)

        await model.setSeen(true)

        XCTAssertTrue(
            scheduled.isCancelled,
            "manual seen toggle must supersede the pending delayed write"
        )
        XCTAssertNil(model.pendingMarkAsReadTask)
    }

    func testSchedulerSkipsWhenPreferenceIsManual() throws {
        // `.manual` is the default. No task should be spawned at all — the
        // scheduler is a no-op — regardless of onDisappear behavior.
        let model = try makeModel(markAsRead: .manual)

        model.scheduleMarkAsReadIfNeeded()

        XCTAssertNil(model.pendingMarkAsReadTask)
    }

    func testSchedulerSkipsWhenMessageAlreadySeen() throws {
        // A message that's already `\Seen` never spawns a delayed task —
        // the scheduler bails at the `guard !isSeen` check before either
        // branch runs. Prevents a re-open from re-scheduling.
        let model = try makeModel(markAsRead: .afterDelay, flags: [.seen])

        model.scheduleMarkAsReadIfNeeded()

        XCTAssertNil(model.pendingMarkAsReadTask)
    }
}
