import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A composer's two autosave loops (`ComposeAutosaveLoops`): each saves when
/// its own interval comes due, `stop()` ends both, and a composer that goes
/// away without `stop()` ends them too, instead of leaving two tasks that
/// wake every 5 and 60 seconds for the rest of the process.
///
/// The loops sleep through `SteppedSleep`, so a test ends an interval rather
/// than waiting it out, and save through `Composer`, which only counts.
@MainActor
final class ComposeAutosaveTests: XCTestCase {
    private static let local = ComposeAutosaveTiming().localInterval
    private static let server = ComposeAutosaveTiming().serverInterval

    /// Counts the saves a composer would make.
    private final class Composer: ComposeAutosaveTarget {
        var localSaves = 0
        var serverSaves = 0

        func persistCurrentDraft() async { localSaves += 1 }
        func autosaveToServer() async { serverSaves += 1 }
    }

    /// A composer that owns its loops, as `ComposeViewModel` does: when it
    /// goes, they go with it.
    private final class OwningComposer: ComposeAutosaveTarget {
        let autosave = ComposeAutosaveLoops()

        func persistCurrentDraft() async {}
        func autosaveToServer() async {}
    }

    /// A sleep that lasts until the test ends it. Unlike `Task.sleep` it
    /// does not end when its task is cancelled, so a stopped loop is still
    /// asleep here until stepped, and what it does on waking can be seen.
    @MainActor
    private final class SteppedSleep {
        private var parked: [TimeInterval: [CheckedContinuation<Void, Never>]] = [:]
        /// How many sleeps of each interval the loops have asked for.
        private(set) var asked: [TimeInterval: Int] = [:]

        var timing: ComposeAutosaveTiming {
            var timing = ComposeAutosaveTiming()
            timing.sleep = { [self] interval in await sleep(interval) }
            return timing
        }

        private func sleep(_ interval: TimeInterval) async {
            asked[interval, default: 0] += 1
            await withCheckedContinuation { parked[interval, default: []].append($0) }
        }

        /// How many loops are asleep on `interval` now.
        func sleepers(on interval: TimeInterval) -> Int {
            parked[interval]?.count ?? 0
        }

        /// The interval comes due: every loop asleep on it wakes.
        func step(_ interval: TimeInterval) {
            parked.removeValue(forKey: interval)?.forEach { $0.resume() }
        }
    }

    private let sleep = SteppedSleep()

    private func makeLoops() -> ComposeAutosaveLoops {
        let loops = ComposeAutosaveLoops()
        loops.timing = sleep.timing
        return loops
    }

    /// Both loops have reached their sleep.
    private func bothAsleep(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntilOnMainActor(file: file, line: line) {
            sleep.sleepers(on: Self.local) == 1 && sleep.sleepers(on: Self.server) == 1
        }
    }

    // MARK: Ticks

    func testTheLocalCopyIsSavedEveryFiveSecondsAndTheServerCopyEveryMinute() {
        XCTAssertEqual(Self.local, 5)
        XCTAssertEqual(Self.server, 60)
    }

    func testEachLoopSavesWhenItsOwnIntervalComesDueAndNotBefore() async throws {
        let composer = Composer()
        let loops = makeLoops()
        loops.start(for: composer)
        try await bothAsleep()
        XCTAssertEqual(composer.localSaves + composer.serverSaves, 0, "a loop saved before its first interval")
        XCTAssertEqual(sleep.asked, [Self.local: 1, Self.server: 1], "each loop sleeps its own interval")

        sleep.step(Self.local)
        try await waitUntilOnMainActor { composer.localSaves == 1 }
        XCTAssertEqual(composer.serverSaves, 0)

        sleep.step(Self.server)
        try await waitUntilOnMainActor { composer.serverSaves == 1 }
        XCTAssertEqual(composer.localSaves, 1)

        // And again: a loop goes back to sleep after it saves.
        try await bothAsleep()
        sleep.step(Self.local)
        sleep.step(Self.server)
        try await waitUntilOnMainActor { composer.localSaves == 2 && composer.serverSaves == 2 }
        loops.stop()
    }

    // MARK: Stopping

    func testStopEndsBothLoops() async throws {
        let composer = Composer()
        let loops = makeLoops()
        loops.start(for: composer)
        try await bothAsleep()
        XCTAssertTrue(loops.isRunning)

        loops.stop()
        XCTAssertFalse(loops.isRunning)

        // Each was asleep when it was stopped: on waking it neither saves
        // nor sleeps again.
        sleep.step(Self.local)
        sleep.step(Self.server)
        let carriedOn = await holdsOnMainActor(within: 0.1) {
            composer.localSaves + composer.serverSaves > 0 || self.sleep.asked != [Self.local: 1, Self.server: 1]
        }
        XCTAssertFalse(carriedOn, "a stopped loop saved or slept again")
    }

    func testStartingAgainReplacesTheLoopsRatherThanAddingToThem() async throws {
        let composer = Composer()
        let loops = makeLoops()
        loops.start(for: composer)
        try await bothAsleep()
        loops.start(for: composer)
        try await waitUntilOnMainActor {
            sleep.sleepers(on: Self.local) == 2 && sleep.sleepers(on: Self.server) == 2
        }

        sleep.step(Self.local)
        sleep.step(Self.server)
        try await bothAsleep()
        XCTAssertEqual(composer.localSaves, 1, "the loops a second start replaced still saved")
        XCTAssertEqual(composer.serverSaves, 1)
        loops.stop()
    }

    // MARK: A composer that goes away

    /// The loops outlive the composer here, so what they do about it shows
    /// in `isRunning`.
    func testAComposerThatGoesAwayEndsBothLoopsWithoutStop() async throws {
        var composer: Composer? = Composer()
        weak let released = composer
        let loops = makeLoops()
        loops.start(for: try XCTUnwrap(composer))
        try await bothAsleep()

        composer = nil
        XCTAssertNil(released, "the loops kept their composer alive")
        XCTAssertTrue(loops.isRunning, "nothing has woken yet")

        // The first loop to wake finds it gone and ends both. A loop that
        // carried on would be asleep again instead.
        sleep.step(Self.local)
        try await waitUntilOnMainActor { !loops.isRunning || self.sleep.asked[Self.local] == 2 }
        XCTAssertFalse(loops.isRunning)

        sleep.step(Self.server)
        let sleptAgain = await holdsOnMainActor(within: 0.1) { self.sleep.asked != [Self.local: 1, Self.server: 1] }
        XCTAssertFalse(sleptAgain, "a loop went back to sleep with no composer to save")
    }

    /// The shape the app has: the composer owns its loops, so they are gone
    /// too by the time a loop wakes.
    func testLoopsThatGoWithTheirComposerEndWhenTheyNextWake() async throws {
        var composer: OwningComposer? = OwningComposer()
        weak let released = composer
        composer?.autosave.timing = sleep.timing
        composer.map { $0.autosave.start(for: $0) }
        try await bothAsleep()

        composer = nil
        XCTAssertNil(released, "the loops kept their composer alive")

        sleep.step(Self.local)
        sleep.step(Self.server)
        let sleptAgain = await holdsOnMainActor(within: 0.1) { self.sleep.asked != [Self.local: 1, Self.server: 1] }
        XCTAssertFalse(sleptAgain, "a loop went back to sleep with no composer to save")
    }

    // MARK: Flush

    func testAFlushSavesTheLocalCopyNowAndLeavesTheServerCopyToItsInterval() async throws {
        let composer = Composer()
        let loops = makeLoops()
        loops.start(for: composer)

        await loops.flush()?.value

        XCTAssertEqual(composer.localSaves, 1)
        XCTAssertEqual(composer.serverSaves, 0)
        loops.stop()
    }

    func testAFlushWritesNothingWhileTheLoopsAreStopped() async throws {
        let composer = Composer()
        let loops = makeLoops()
        XCTAssertNil(loops.flush(), "flushed before the composer started")

        loops.start(for: composer)
        loops.stop()
        XCTAssertNil(loops.flush(), "flushed after the composer closed")
        XCTAssertEqual(composer.localSaves, 0)
    }

    /// A draft discarded in the turn that asked for the flush is not written
    /// back: the flush reads `isRunning` when its save starts, as a tick
    /// reads its cancellation.
    func testAStopThatOvertakesAFlushWins() async throws {
        let composer = Composer()
        let loops = makeLoops()
        loops.start(for: composer)

        let flush = loops.flush()
        loops.stop()
        await flush?.value

        XCTAssertEqual(composer.localSaves, 0)
    }

    // MARK: The composer itself

    func testARealComposersLocalTickWritesItsDraft() async throws {
        let model = try TestFixtures.makeComposeModel(seed: Draft(subject: "autosave probe"))
        model.autosave.timing = sleep.timing
        model.autosave.start(for: model)
        defer { model.stop() }
        try await bothAsleep()
        let before = try await model.draftStore.load(id: model.draftId)
        XCTAssertNil(before, "nothing is written before the first interval")

        sleep.step(Self.local)

        try await waitUntilOnMainActor {
            try await model.draftStore.load(id: model.draftId)?.subject == "autosave probe"
        }
    }
}
