import Foundation

/// Waits for the target app to have drawn something a query could find,
/// and refuses rather than letting a query answer a false negative (#1436).
///
/// For the first seconds after the app is relaunched under a live runner —
/// `xcrun simctl terminate` + `launch` from the host, which is the standard
/// way to reach a launch-time state — the app is running but has drawn
/// nothing at all. In that window `dump` answers `ok: true` carrying the
/// query chain and no elements, and `exists`/`focus` answer their ordinary
/// not-found. Every one of those is a *successful negative*, indistinguishable
/// from a real one: an arm that queried too early recorded a clean false
/// negative twice in one session before the window was understood.
///
/// The cure is the shape `requireRunningApp()` already uses for the
/// app-not-running case (#902): turn the lie into an ordinary error result.
/// This gate polls until the tree arrives, which is what the caller wanted
/// anyway, and only errors when it never does.
///
/// The schedule is a value with an injected clock, sleep and probe so it can
/// be tested without a simulator. The probe itself — whether the application
/// element has any children — is the runner's to supply and is only
/// verifiable live; keeping it out of here is what stops the tests pinning a
/// rule the runner does not actually use.
struct TreeReadyGate {

    /// Long enough to cover a cold launch of the app under test (the runner
    /// sees a populated tree within ~3-7s of `simctl launch` on this
    /// hardware, and the spread between arms is nearly as wide as the
    /// window itself), short enough that a genuinely blank app answers
    /// inside one command's patience rather than the caller's.
    static let defaultTimeout: TimeInterval = 10

    /// A tree that is one probe away should not cost a whole second.
    static let defaultPollInterval: TimeInterval = 0.25

    var timeout: TimeInterval = defaultTimeout
    var pollInterval: TimeInterval = defaultPollInterval

    /// What the wait cost, for a caller that wants to report it.
    struct Outcome: Equatable {
        /// How many times the probe ran; 1 means the tree was already there.
        var probes: Int
        /// Seconds spent waiting, by the injected clock.
        var waited: TimeInterval
    }

    /// The error a caller gets instead of a false negative.
    ///
    /// It has to say that *nothing* was found rather than that the queried
    /// element was absent, because those are the two readings the empty tree
    /// makes indistinguishable and the whole point of the gate is to tell
    /// them apart.
    struct NotDrawn: LocalizedError, Equatable {
        let bundleId: String
        let waited: TimeInterval

        var errorDescription: String? {
            "target app \(bundleId) is running but has drawn nothing after "
                + String(format: "%.1f", waited)
                + "s — its accessibility tree is empty, so this is not a "
                + "negative answer about the query, it is no answer at all"
        }
    }

    /// Polls `isPopulated` until it answers true, or throws `NotDrawn`.
    ///
    /// Probes before sleeping, so an already-drawn app costs exactly one
    /// probe and no delay — the overwhelmingly common case, and the one a
    /// gate on every command must not tax.
    @discardableResult
    func wait(
        bundleId: String,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        isPopulated: () -> Bool
    ) throws -> Outcome {
        let start = now()
        var probes = 0
        while true {
            probes += 1
            if isPopulated() {
                return Outcome(probes: probes, waited: now() - start)
            }
            let elapsed = now() - start
            if elapsed >= timeout {
                throw NotDrawn(bundleId: bundleId, waited: elapsed)
            }
            sleep(pollInterval)
        }
    }
}
