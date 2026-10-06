import Foundation
import Observation
import CabalmailKit

/// The mail state the folder list, message list, reader and composer share
/// for the signed-in account, in parts that each own a piece of it:
/// `counts`, the folder badges and the Inbox count behind the app badge.
///
/// `AppState` owns one (`mailStore`) for its whole life and resets it in place
/// at sign-out (`forgetAccount()`), so a view model, or a reader callback that
/// outlives a session, never writes into a store nobody reads.
@Observable
@MainActor
public final class MailSessionStore {
    public let counts = MailCounts()

    /// The session lifecycle's record of which clients' sessions have ended
    /// (`AppState.teardownGate`, which marks a client ended before sign-out
    /// resets this store). `acceptsCounts(from:)` answers from it.
    @ObservationIgnored private let teardownGate: SessionTeardownGate

    init(teardownGate: SessionTeardownGate = SessionTeardownGate()) {
        self.teardownGate = teardownGate
    }

    /// Whether counts fetched through `client` still belong to the account
    /// on screen: false once its session has started ending. A STATUS that
    /// answers during or after a sign-out would otherwise write the last
    /// account's counts back after the reset, where the next account starts
    /// from them and saves their totals as its own (#1848). Every writer of a
    /// count it fetched checks this after the fetch, and so does every
    /// unread change that lands after a server call: a revert when the call
    /// fails, or a change applied once it answers (#1851).
    func acceptsCounts(from client: CabalmailClient) -> Bool {
        !teardownGate.hasEnded(client)
    }

    /// Sign-out: what the store knows about the account goes, so the next
    /// account starts from none of it (#1825).
    func forgetAccount() {
        counts.reset()
    }
}
