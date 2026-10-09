import Foundation

/// The folder list's single-flight refresh bookkeeping (#1820).
///
/// A pass is one STATUS and the window work that follows it. One runs at a
/// time. A refresh asked for while a pass is out parks until that pass ends,
/// because the pass's STATUS may predate whatever prompted the ask, and is
/// then answered by the next pass, which asks STATUS afresh. However many
/// refreshes park meanwhile, they share that one rerun. A reset's refresh
/// (`hardReload`, `setSort`, leaving a search) begins its pass at once and
/// supersedes the one out, whose rows the reset has already dropped.
///
/// Asks are numbered in order. A pass answers every ask made before its
/// STATUS was asked, once it ends without being cancelled or superseded:
/// every ask before it began, or, for a pass handed a STATUS asked for
/// earlier (a reset's probe, a folder poll), every ask before that STATUS.
struct RefreshFlight {
    /// A pass in flight: its number, and the last ask it answers.
    struct Pass: Equatable {
        let id: Int
        let answers: Int
    }

    /// The pass in flight, nil when none is.
    private(set) var current: Pass?
    private var asks = 0
    private var answered = 0
    private var passes = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Refreshes parked until the pass in flight ends.
    var waiting: Int { parked.count }

    /// Numbers a new ask for a refresh.
    mutating func ask() -> Int {
        asks += 1
        return asks
    }

    /// Whether a pass whose STATUS was asked for after `ask` has ended
    /// uncancelled.
    func hasAnswered(_ ask: Int) -> Bool {
        answered >= ask
    }

    /// Starts a pass, superseding any still in flight. `answeringThrough` is
    /// the last ask made before the STATUS the pass was handed was asked for;
    /// a pass that asks its own STATUS answers every ask so far.
    mutating func begin(answeringThrough last: Int? = nil) -> Pass {
        passes += 1
        let pass = Pass(id: passes, answers: min(asks, last ?? asks))
        current = pass
        return pass
    }

    /// Ends `pass` and hands back the refreshes parked on it, for the caller
    /// to resume. A superseded pass answers nothing and hands back nothing:
    /// what parked during it waits for the pass that superseded it.
    mutating func end(_ pass: Pass, finished: Bool) -> [CheckedContinuation<Void, Never>] {
        guard current == pass else { return [] }
        current = nil
        if finished { answered = max(answered, pass.answers) }
        let resumed = parked
        parked = []
        return resumed
    }

    /// Parks a refresh until the pass in flight ends.
    mutating func park(_ waiter: CheckedContinuation<Void, Never>) {
        parked.append(waiter)
    }
}
