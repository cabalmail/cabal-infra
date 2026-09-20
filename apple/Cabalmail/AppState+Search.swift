import Foundation
import CabalmailKit

// The search model the two iOS layout trees share. In its own file, like the
// feeds and subscriptions extensions, to keep `AppState.swift` under
// SwiftLint's file-length cap; the stored property lives in the class.
extension AppState {
    /// The process-wide search model, created on first use for `client` and
    /// handed to whichever layout tree is showing search.
    ///
    /// The compact Search tab and the regular split each used to own a
    /// `MessageListViewModel(scope: .search)` in `@State`, so a layout swap —
    /// closing an iPhone Duo, or narrowing an iPad window — built a fresh one
    /// and the query and results were gone (#1654). Folder, message, and feed
    /// position survive that swap through the resume session; search did not
    /// deserve a persisted session (results should not outlive the process),
    /// so it lives here instead. Keyed on the client: a new sign-in gets a new
    /// model, and sign-out drops it with the client.
    func sharedSearchModel(client: CabalmailClient, preferences: Preferences) -> MessageListViewModel {
        if let existing = searchModelStore, existing.client === client { return existing }
        let model = MessageListViewModel(scope: .search, client: client, preferences: preferences, appState: self)
        searchModelStore = model
        return model
    }
}
