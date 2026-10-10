import Foundation
import CabalmailKit

/// A link into the app from outside any window: a tapped notification, a
/// Spotlight result, Siri's Open Folder.
public enum DeepLink: Equatable, Sendable {
    /// A message (or folder) by cursor: a notification tap.
    case message(NavState)
    /// A Spotlight result, whose Message-ID the receiving window looks up
    /// in the envelope cache.
    case spotlight(SpotlightMessageRef)
    /// A folder to open: Siri's Open Folder.
    case folder(String)
}

/// Delivers each deep link to exactly one main window.
///
/// The window the system targeted takes it when it is known: on iPad, the
/// window a notification is shown over, or the window that received a
/// Spotlight result. Else the window the user last used, else the window
/// most recently opened. With no main window to take it (a cold launch, or
/// before the session is wired), the link parks, the last one winning, for
/// the first window to open. Only that window acts on it, with
/// `SceneNavigator.navigate(to:)`; no other window sees it.
///
/// Before, push, Spotlight and Siri each kept their own parking place and
/// wrote one app-wide request that every window observed, and the first
/// window to notice took it, whichever window the system meant.
///
/// The account rules drop a parked link (`discardParked()`): a sign-out or
/// an expiry (`AppState.forgetAccountState`), another account's sign-in
/// (`AppState`'s `accountChanged` hook, `PushRegistrar.forgetOtherAccount`),
/// and the end of a session (`PushRegistrar.sessionWillEnd`). While a
/// session ends, a link parks rather than open in a window about to close.
@MainActor
public final class DeepLinkRouter {
    /// The app's router. `AppState()` makes its own, so tests stay apart;
    /// the app entries' `AppState(sessionManager:)` takes this one, as do
    /// `PushRegistrar.shared` and `IntentBridge`.
    public static let shared = DeepLinkRouter()

    /// The link waiting for a window to open; the last one wins.
    private(set) var parked: DeepLink?

    /// The app state the router reads the window last used and the session
    /// from. Set by `AppState.init`.
    weak var appState: AppState?

    /// Opens a main window when a link parks while a session is wired: on
    /// the Mac, a notification or a Spotlight result with every main window
    /// closed. Set by the Mac app entry.
    public var opensMainWindow: (@MainActor () -> Void)?

    /// The main windows' navigators, by window.
    private var windows = WindowRegistry<SceneNavigator>()

    /// Counts every link opened or discarded, so a Spotlight result still
    /// looking up its Message-ID gives way to anything that came after it.
    private(set) var generation = 0

    init() {}

    /// Opens `link` in `window` when that is a main window (the system's
    /// target), else in the window last used, else in the window most
    /// recently opened; with none of them, parks it.
    public func open(_ link: DeepLink, in window: UUID? = nil) {
        generation += 1
        guard let navigator = receiver(for: window) else {
            parked = link
            if appState?.client != nil, !(appState?.isEndingSession ?? false) { opensMainWindow?() }
            return
        }
        parked = nil
        navigator.open(link)
    }

    /// The navigator that takes a link aimed at `window`. None while a
    /// session ends: the link parks for the next session's first window,
    /// which the account rules may yet drop.
    private func receiver(for window: UUID?) -> SceneNavigator? {
        guard appState?.isEndingSession != true else { return nil }
        return windows.value(for: window) ?? windows.value(for: appState?.lastActiveMainWindow) ?? windows.latest
    }

    /// A main window's navigator, under its window identity. A link parked
    /// before the window existed opens in it.
    func register(_ navigator: SceneNavigator) {
        guard let window = navigator.windowID else { return }
        windows.register(navigator, for: window)
        if let link = takeParked() { navigator.open(link) }
    }

    /// The window `navigator` belongs to has gone.
    func unregister(_ navigator: SceneNavigator) {
        guard let window = navigator.windowID else { return }
        windows.remove(window, holding: navigator)
    }

    /// A link a window could not open after all (its session ended under
    /// it): it parks again, unless another has parked since.
    func giveBack(_ link: DeepLink) {
        if parked == nil { parked = link }
    }

    /// Takes the parked link, for a window's first landing.
    func takeParked() -> DeepLink? {
        defer { parked = nil }
        return parked
    }

    /// Drops the parked link: an account rule, or a navigation in a window
    /// that supersedes it.
    func discardParked() {
        generation += 1
        parked = nil
    }
}

extension NavStateCoordinator {
    /// The cursor `link` opens, when it needs no lookup: a notification's
    /// own, or Siri's folder.
    func immediateCursor(for link: DeepLink) -> NavState? {
        switch link {
        case .message(let cursor): cursor
        case .folder(let path): NavState(folder: path, clientID: clientID)
        case .spotlight: nil
        }
    }

    /// The cursor `link` opens. A Spotlight result names (folder, UID); its
    /// durable Message-ID comes from the envelope cache, so the list can
    /// still find a message another client has moved since.
    func cursor(for link: DeepLink) async -> NavState {
        switch link {
        case .message(let cursor):
            return cursor
        case .folder(let path):
            return NavState(folder: path, clientID: clientID)
        case .spotlight(let ref):
            let messageID = await client.envelopeCache.snapshot(for: ref.folder)?.envelopes[ref.uid]?.messageId
            return NavState(folder: ref.folder, messageID: messageID, uid: ref.uid, clientID: clientID)
        }
    }
}
