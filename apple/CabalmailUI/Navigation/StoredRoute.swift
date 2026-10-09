import SwiftUI
import CabalmailKit

/// One main window's route as its scene storage keeps it
/// (`@SceneStorage("route")` on `ContentView`), tagged with the account it
/// belongs to, so a window the system restores comes back where it was and
/// never on another account's place.
///
/// The JSON holds the route by ID only (`AppRoute`): no tab, column, search
/// or selection. Every main window clears its own at a sign-out
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

    /// The route `data` holds for `account`: nil when nothing is stored,
    /// when it does not decode, or when it is another account's.
    static func route(in data: Data?, for account: Account) -> AppRoute? {
        guard let data, let stored = try? JSONDecoder().decode(StoredRoute.self, from: data),
              stored.account == account
        else { return nil }
        return stored.route
    }

    /// `route` encoded for `account`'s window.
    static func data(_ route: AppRoute, for account: Account) -> Data? {
        try? JSONEncoder().encode(StoredRoute(account: account, route: route))
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
    let navigator: SceneNavigator
    @Binding var storedRoute: Data?

    func body(content: Content) -> some View {
        content
            .onChange(of: navigator.route) { _, route in
                guard appState.status == .signedIn, !appState.isEndingSession else { return }
                storedRoute = StoredRoute.data(route, for: appState.routeAccount)
            }
            .onChange(of: appState.lastActiveMainWindow) { _, window in
                if let window, window == navigator.windowID { navigator.becameLastUsed() }
            }
    }
}
