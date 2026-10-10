import SwiftUI
import CabalmailKit

/// One main window's route as its scene storage keeps it
/// (`@SceneStorage("route")` on `ContentView`), tagged with the account it
/// belongs to, so a window the system restores comes back where it was and
/// never on another account's place.
///
/// The JSON holds the route by ID only (`AppRoute`): no tab, column, search
/// or selection. Beside the route, not in it, go where the window's folder
/// list is scrolled (`listAnchor`) and whether the window was the one last
/// used, written when the route changes, when the scene leaves the
/// foreground and when the window last used changes. Every main window clears its own at a sign-out
/// (`AppState.accountForgottenTick`); a window the system kept but had not
/// mounted then still holds one, which only the same account reads back.
struct StoredRoute: Codable, Equatable {
    /// The account a route belongs to: what `SessionManager` persists for
    /// the sign-in form.
    struct Account: Codable, Hashable {
        var controlDomain: String
        var username: String
    }

    var account: Account
    var route: AppRoute
    /// Where the window's folder list was scrolled (`ListAnchor`); nil at
    /// the top, and in a route stored before this was kept.
    var listAnchor: ListAnchor?
    /// Whether this was the window last used when it was stored: the one
    /// whose list place the resume session was following.
    var wasLastUsed: Bool?

    /// The stored list place, when it is for the route's folder.
    var listPlace: ListAnchor? {
        listAnchor?.folderPath == route.mail.folderPath ? listAnchor : nil
    }

    /// The list place a restored window reopens at. The window last used
    /// reopens at the session's place for its folder, which was recorded as
    /// its list scrolled; the window's own is written only with its route
    /// and as its scene leaves the foreground, and a Mac that quits straight
    /// after a scroll does neither. Any other window reopens at its own.
    func placeToReopen(session: ResumeSession?) -> ListAnchor? {
        if wasLastUsed == true, let session, let folder = route.mail.folderPath, session.folder == folder {
            return session.listAnchor
        }
        return listPlace
    }

    /// What `data` holds for `account`: nil when nothing is stored, when it
    /// does not decode, or when it is another account's.
    static func stored(in data: Data?, for account: Account) -> StoredRoute? {
        guard let data, let stored = try? JSONDecoder().decode(StoredRoute.self, from: data),
              stored.account == account
        else { return nil }
        return stored
    }

    /// The route `data` holds for `account`.
    static func route(in data: Data?, for account: Account) -> AppRoute? {
        stored(in: data, for: account)?.route
    }

    /// `route` encoded for `account`'s window, with its list's place.
    static func data(_ route: AppRoute, listAnchor: ListAnchor? = nil, for account: Account) -> Data? {
        try? JSONEncoder().encode(StoredRoute(account: account, route: route, listAnchor: listAnchor))
    }
}

extension AppState {
    /// The account a window's stored route belongs to.
    var routeAccount: StoredRoute.Account {
        StoredRoute.Account(controlDomain: controlDomain, username: lastUsername)
    }

    /// Whether a session is ending: a route a window moves to now is not
    /// stored, since the sign-out clearing the stored routes has begun.
    var isEndingSession: Bool {
        sessionManager.teardownGate.isTearingDown
    }
}

/// Keeps a main window's stored route current as the window moves, and
/// hands the window the recording when it becomes the one the user last
/// used (`SceneNavigator.becameLastUsed`). A modifier so the route and the
/// registry it reads re-render it alone, not the window's root.
struct WindowPlaceKeeper: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    let navigator: SceneNavigator
    @Binding var storedRoute: Data?

    func body(content: Content) -> some View {
        content
            .onChange(of: navigator.route) { store() }
            // The list's place goes in as the scene leaves the foreground,
            // and with each route; never per scroll, since every write
            // re-renders the window's root.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store() }
            }
            .onChange(of: appState.lastActiveMainWindow) { _, window in
                if let window, window == navigator.windowID { navigator.becameLastUsed() }
                // Which window was last used is stored with each.
                store()
            }
    }

    private func store() {
        guard appState.status == .signedIn, !appState.isEndingSession else { return }
        let isLastUsed = navigator.windowID.map { $0 == appState.lastActiveMainWindow } ?? false
        let place = StoredRoute(
            account: appState.routeAccount, route: navigator.route, listAnchor: navigator.listPlace,
            wasLastUsed: isLastUsed
        )
        guard place != StoredRoute.stored(in: storedRoute, for: place.account) else { return }
        storedRoute = try? JSONEncoder().encode(place)
    }
}
