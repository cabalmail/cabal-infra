import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Clears the per-subscription `WKWebsiteDataStore`s of departed
/// subscriptions (D11: a feed's cookies and site data leave with it). Only
/// the app layer has WebKit, so the Kit records the identifiers and this
/// clears them: after every catalog sync (sidebar refresh, management
/// flows, the poller) via `dropDeparted`, and all of them on sign-out.
///
/// Deliberately the instance API (`removeData(ofTypes:modifiedSince:)` on a
/// store opened for the identifier), not the class-level
/// `WKWebsiteDataStore.remove(forIdentifier:)`: on macOS 26 the class API
/// (and `allDataStoreIdentifiers`) segfaults in a process that has not yet
/// stood up a web view, which is exactly the state after unsubscribing a
/// feed whose article was never opened. Reproduced standalone 2026-09-10.
/// The emptied store's directory may linger; its contents do not.
enum FeedWebStorage {
    /// Drops the storage of every subscription the store has removed since
    /// the last call, whichever sync path removed it.
    @MainActor
    static func dropDeparted(from store: RssStore?) async {
        guard let store, let uuids = try? await store.takeDepartedDataStoreUuids(), !uuids.isEmpty else { return }
        drop(uuids: uuids)
    }

    @MainActor
    static func drop(uuids: [String]) {
        #if canImport(WebKit)
        for raw in uuids {
            guard let uuid = UUID(uuidString: raw) else { continue }
            Task {
                let store = WKWebsiteDataStore(forIdentifier: uuid)
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
        #endif
    }
}
