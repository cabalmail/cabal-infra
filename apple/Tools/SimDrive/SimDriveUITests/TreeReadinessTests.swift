import XCTest

/// #1436: for a few seconds after a host-side relaunch the target app is
/// running and has drawn nothing, and every query answered a successful
/// negative indistinguishable from a real one.
///
/// The schedule is what these pin. The probe the runner actually supplies —
/// whether the application element has any children — is only verifiable
/// against a live simulator and is deliberately not modelled here; a fake of
/// it would pin a rule the runner does not run.
final class TreeReadinessTests: XCTestCase {

    /// A clock that only moves when something sleeps, so a schedule assertion
    /// is exact rather than timing-dependent.
    private final class FakeClock {
        private(set) var now: TimeInterval = 0
        private(set) var sleeps: [TimeInterval] = []

        func sleep(_ interval: TimeInterval) {
            sleeps.append(interval)
            now += interval
        }
    }

    /// Answers false `falseAnswers` times, then true forever.
    private final class Probe {
        private var remaining: Int
        private(set) var calls = 0

        init(falseAnswers: Int) { remaining = falseAnswers }

        func isPopulated() -> Bool {
            calls += 1
            if remaining > 0 {
                remaining -= 1
                return false
            }
            return true
        }
    }

    private func drive(
        gate: TreeReadyGate,
        probe: Probe,
        clock: FakeClock
    ) throws -> TreeReadyGate.Outcome {
        try gate.wait(
            bundleId: "com.cabalmail.Cabalmail",
            now: { clock.now },
            sleep: clock.sleep,
            isPopulated: probe.isPopulated
        )
    }

    // MARK: - The common case must stay free

    /// The gate runs before every tree-reading verb, so a drawn app has to
    /// cost one probe and no delay or it taxes the whole session.
    func testADrawnAppCostsOneProbeAndNoDelay() throws {
        let clock = FakeClock()
        let probe = Probe(falseAnswers: 0)
        let outcome = try drive(gate: TreeReadyGate(), probe: probe, clock: clock)
        XCTAssertEqual(outcome, TreeReadyGate.Outcome(probes: 1, waited: 0))
        XCTAssertEqual(clock.sleeps, [], "an already-drawn app must not sleep")
        XCTAssertEqual(probe.calls, 1)
    }

    // MARK: - The reported window

    /// The measured window is ~2-3s, and the whole point is that the command
    /// then answers correctly rather than answering a false negative.
    func testATreeThatArrivesMidWaitIsWaitedFor() throws {
        let clock = FakeClock()
        let probe = Probe(falseAnswers: 11)  // 11 x 0.25s = 2.75s
        let outcome = try drive(gate: TreeReadyGate(), probe: probe, clock: clock)
        XCTAssertEqual(outcome.probes, 12)
        XCTAssertEqual(outcome.waited, 2.75, accuracy: 0.0001)
        XCTAssertEqual(clock.sleeps.count, 11)
        XCTAssertEqual(clock.sleeps.allSatisfy { $0 == 0.25 }, true)
    }

    // MARK: - The refusal

    func testAnAppThatNeverDrawsIsAnErrorNotAnEmptyAnswer() {
        let clock = FakeClock()
        let probe = Probe(falseAnswers: .max)
        XCTAssertThrowsError(
            try drive(gate: TreeReadyGate(), probe: probe, clock: clock)
        ) { error in
            guard let notDrawn = error as? TreeReadyGate.NotDrawn else {
                return XCTFail("expected NotDrawn, got \(error)")
            }
            XCTAssertEqual(notDrawn.bundleId, "com.cabalmail.Cabalmail")
            XCTAssertEqual(notDrawn.waited, TreeReadyGate.defaultTimeout, accuracy: 0.0001)
        }
        // Bounded: the budget divided by the interval, plus the probe that
        // runs before the first sleep and the one that finds the deadline.
        XCTAssertEqual(probe.calls, 41)
        XCTAssertEqual(clock.sleeps.count, 40)
    }

    /// The message is what a recipe author reads at the moment their command
    /// stopped working, and the reading it has to prevent is "the element I
    /// asked for is not there".
    func testTheRefusalSaysNothingWasDrawnRatherThanNotFound() throws {
        let error = TreeReadyGate.NotDrawn(bundleId: "com.cabalmail.Cabalmail", waited: 10)
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("com.cabalmail.Cabalmail"))
        XCTAssertTrue(
            message.contains("drawn nothing"),
            "the error has to name the empty tree, not the query: \(message)"
        )
        XCTAssertTrue(
            message.contains("10.0s"),
            "how long it waited is what tells a caller whether to wait longer: \(message)"
        )
    }

    /// A zero budget is the degenerate case the loop shape has to survive:
    /// one probe, no sleep, an honest error.
    func testAZeroTimeoutProbesOnceAndDoesNotSleep() {
        let clock = FakeClock()
        let probe = Probe(falseAnswers: .max)
        let gate = TreeReadyGate(timeout: 0, pollInterval: 0.25)
        XCTAssertThrowsError(try drive(gate: gate, probe: probe, clock: clock))
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    /// A probe that answers true on the very last round still returns rather
    /// than throwing — the deadline is checked after the probe, not before.
    func testATreeThatArrivesOnTheLastRoundIsNotRefused() throws {
        let clock = FakeClock()
        let probe = Probe(falseAnswers: 40)
        let outcome = try drive(gate: TreeReadyGate(), probe: probe, clock: clock)
        XCTAssertEqual(outcome.probes, 41)
        XCTAssertEqual(outcome.waited, TreeReadyGate.defaultTimeout, accuracy: 0.0001)
    }
}
