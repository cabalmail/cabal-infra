import Foundation

/// The calls of a scripted double that a test can hold open at the transport,
/// so an answer can be made to land after something else has happened: a
/// search result arriving once the user has ended the search (#1536), or a
/// refresh fetched before a dispose's move landed that only arrives once the
/// dispose has finished.
///
/// A test arms the next call of a kind (`arm`), the double parks that call
/// when it arrives (`disarm`, then `park`), the test can wait for it to
/// arrive (`isParked`, then `waitForArrival`), and `release` lets it answer
/// with whatever is scripted by then.
///
/// A value the double stores and mutates, not an actor of its own: every
/// step runs inside the double's isolation, in the continuation body its
/// caller is already suspended on, so holding a call adds no suspension
/// point beyond the one the hold itself is.
struct CallGate<Call: Hashable & Sendable> {
    /// Kinds whose next call parks.
    private var armed: Set<Call> = []
    /// Calls parked now, waiting on `release`.
    private var parked: [Call: CheckedContinuation<Void, Never>] = [:]
    /// Tests waiting for a call of a kind to arrive and park.
    private var arrivals: [Call: CheckedContinuation<Void, Never>] = [:]

    /// The next call of this kind parks when it arrives.
    mutating func arm(_ call: Call) {
        armed.insert(call)
    }

    /// Takes the hold for a call that has just arrived. Returns whether it
    /// should park; a hold covers one call, so the next passes.
    mutating func disarm(_ call: Call) -> Bool {
        armed.remove(call) != nil
    }

    /// Parks an arrived call on `continuation` and wakes the test waiting
    /// for it.
    mutating func park(_ call: Call, on continuation: CheckedContinuation<Void, Never>) {
        parked[call] = continuation
        arrivals.removeValue(forKey: call)?.resume()
    }

    /// Whether a call of this kind is parked now, so a test need not wait
    /// for it.
    func isParked(_ call: Call) -> Bool {
        parked[call] != nil
    }

    /// Resumes `continuation` when a call of this kind parks.
    mutating func waitForArrival(of call: Call, on continuation: CheckedContinuation<Void, Never>) {
        arrivals[call] = continuation
    }

    /// Lets the parked call of this kind answer. A hold that no call has
    /// taken yet stays armed.
    mutating func release(_ call: Call) {
        parked.removeValue(forKey: call)?.resume()
    }
}
