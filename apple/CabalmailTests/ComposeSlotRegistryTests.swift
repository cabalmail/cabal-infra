import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1084: the compose `WindowGroup` was keyed
// by the seed `Draft`, and every session mints a fresh `UUID`, so SwiftUI
// retained one presentation (model + WKWebView, ~8-9 MB) per compose
// session for the life of the process with nothing ever retiring the key.
// Measured on iPad and macOS: zero `deinit`s across seven sessions.
//
// The window value is now a recycled slot index. These tests pin the two
// properties the fix depends on: a slot is reused once its composer
// closes (which is what bounds the retained presentations), and a reused
// slot hands out the NEW seed (which is what stops the recycled window
// coming back with the previous session's content).
@MainActor
final class ComposeSlotRegistryTests: XCTestCase {

    // MARK: - Recycling

    func testClosedSlotIsReused() {
        let registry = ComposeSlotRegistry()

        let first = registry.acquire(seed: Draft())
        registry.release(first)
        let second = registry.acquire(seed: Draft())

        XCTAssertEqual(second, first, "a freed slot must be handed out again")
    }

    func testSequentialSessionsAllPinToSlotZero() {
        let registry = ComposeSlotRegistry()

        for _ in 0..<8 {
            let slot = registry.acquire(seed: Draft())
            XCTAssertEqual(slot.index, 0)
            registry.release(slot)
        }
        XCTAssertEqual(registry.openCount, 0)
    }

    // MARK: - Side-by-side compose survives

    func testConcurrentComposersGetDistinctSlots() {
        let registry = ComposeSlotRegistry()

        let reply = registry.acquire(seed: Draft(subject: "reply"))
        let forward = registry.acquire(seed: Draft(subject: "forward"))

        XCTAssertNotEqual(reply, forward)
        XCTAssertEqual(registry.seed(for: reply)?.subject, "reply")
        XCTAssertEqual(registry.seed(for: forward)?.subject, "forward")
        XCTAssertEqual(registry.openCount, 2)
    }

    func testSlotsAreBoundedByConcurrentComposersNotSessions() {
        let registry = ComposeSlotRegistry()

        // Two open at once, then twenty sequential sessions on top.
        let held = [registry.acquire(seed: Draft()), registry.acquire(seed: Draft())]
        var highWater = 0
        for _ in 0..<20 {
            let slot = registry.acquire(seed: Draft())
            highWater = max(highWater, slot.index)
            registry.release(slot)
        }

        XCTAssertEqual(highWater, 2, "sequential sessions must not climb past the held slots")
        XCTAssertEqual(held.count, 2)
    }

    func testClosingAMiddleComposerFreesThatSlotFirst() {
        let registry = ComposeSlotRegistry()

        _ = registry.acquire(seed: Draft())
        let middle = registry.acquire(seed: Draft())
        _ = registry.acquire(seed: Draft())
        registry.release(middle)

        XCTAssertEqual(registry.acquire(seed: Draft()), middle)
    }

    // MARK: - Reset on reuse

    func testReusedSlotHandsOutTheNewSeed() {
        let registry = ComposeSlotRegistry()

        let first = registry.acquire(seed: Draft(subject: "stale"))
        registry.release(first)
        let second = registry.acquire(seed: Draft(subject: "fresh"))

        XCTAssertEqual(registry.seed(for: second)?.subject, "fresh")
    }

    func testReusedSlotChangesSeedIdentitySoTheSubtreeRebuilds() {
        // `ComposeWindowContent` re-identifies on `seed.id`; if a recycled
        // slot kept the old identity the window would come back with the
        // previous session's model, which is exactly the correctness bug
        // that killed the "one constant window value" variant of this fix.
        let registry = ComposeSlotRegistry()

        let first = registry.acquire(seed: Draft())
        let firstID = registry.seed(for: first)?.id
        registry.release(first)
        let second = registry.acquire(seed: Draft())

        XCTAssertNotEqual(registry.seed(for: second)?.id, firstID)
    }

    func testReleaseKeepsTheSeedUntilTheSlotIsReacquired() {
        // Clearing on release would make the still-mounted window rebuild
        // an empty composer on its way out.
        let registry = ComposeSlotRegistry()

        let slot = registry.acquire(seed: Draft(subject: "closing"))
        registry.release(slot)

        XCTAssertEqual(registry.seed(for: slot)?.subject, "closing")
    }

    // MARK: - mailto: reseeding

    func testReseedReplacesTheSeedOfAnOpenSlot() {
        let registry = ComposeSlotRegistry()

        let slot = registry.acquire(seed: Draft())
        registry.reseed(slot, with: Draft(to: ["someone@example.com"]))

        XCTAssertEqual(registry.seed(for: slot)?.to, ["someone@example.com"])
        XCTAssertEqual(registry.openCount, 1)
    }

    func testReseedOccupiesASlotTheProcessNeverHandedOut() {
        // A mailto: cold launch spawns the window itself; the URL arrives
        // afterwards and must not leave the slot free for a second
        // composer to claim underneath it.
        let registry = ComposeSlotRegistry()

        registry.reseed(ComposeSlot(index: 0), with: Draft(subject: "mailto"))

        XCTAssertEqual(registry.openCount, 1)
        XCTAssertEqual(registry.acquire(seed: Draft()).index, 1)
    }

    // MARK: - Restored scenes

    func testUnknownSlotHasNoSeed() {
        XCTAssertNil(ComposeSlotRegistry().seed(for: ComposeSlot(index: 3)))
    }

    func testRestoredSeedIsStableForASlotAndDistinctBetweenSlots() {
        // The fallback identity has to be derived, not minted: a fresh
        // `UUID` per body evaluation would rebuild the composer on every
        // redraw.
        let first = ComposeSlotRegistry.restoredSeed(for: ComposeSlot(index: 1))
        let again = ComposeSlotRegistry.restoredSeed(for: ComposeSlot(index: 1))
        let other = ComposeSlotRegistry.restoredSeed(for: ComposeSlot(index: 2))

        XCTAssertEqual(first.id, again.id)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertTrue(first.isEmpty)
    }

    // MARK: - Window value shape

    func testSlotRoundTripsThroughCodableAsTheWindowValueMust() {
        // `WindowGroup(for:)` persists the value for scene restoration.
        let encoded = try? JSONEncoder().encode(ComposeSlot(index: 4))
        let decoded = encoded.flatMap { try? JSONDecoder().decode(ComposeSlot.self, from: $0) }

        XCTAssertEqual(decoded, ComposeSlot(index: 4))
    }
}
