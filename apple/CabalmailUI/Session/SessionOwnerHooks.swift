import Foundation
import CabalmailKit

/// What a session's start and end do to `AppState`'s own state: the mail
/// store, a parked Spotlight result, attachment folders, compose windows, the
/// shared search model and the contacts prompt. `AppState.init` installs
/// them on its `SessionManager`, which calls each at the point in the
/// wiring or teardown where it always ran. Until then they do nothing.
@MainActor
struct SessionOwnerHooks {
    /// The app state the platform hooks are handed
    /// (`SessionHooks.sessionDidStart`: push routing, the Intents bridge).
    var appState: @MainActor () -> AppState? = { nil }
    /// Wiring, as the client is installed: the mail store's saved counts
    /// read the client's folder state.
    var clientInstalled: @MainActor (CabalmailClient) -> Void = { _ in }
    /// Wiring, after `.signedIn` and the badge poller: the contacts prompt.
    var requestContactsAccess: @MainActor () -> Void = {}
    /// Wiring, after the Spotlight sweep starts: route a Spotlight result
    /// tapped before the session was wired.
    var routeParkedOpens: @MainActor () -> Void = {}
    /// An interactive sign-in for another account than the last one: a
    /// Spotlight result parked for that account goes (#1825).
    var accountChanged: @MainActor () -> Void = {}
    /// The badge poller's Inbox count, and 0 when it stops.
    var inboxUnreadChanged: @MainActor (Int) -> Void = { _ in }
    /// Teardown, before the session's client ends: what this process knows
    /// about the account goes, with or without a client (#1825).
    var forgetAccount: @MainActor () -> Void = {}
    /// Teardown, in the same turn the client is dropped: compose windows
    /// end their session and the shared search model goes.
    var clientDropped: @MainActor () -> Void = {}
}
