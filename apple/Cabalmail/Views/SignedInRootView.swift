import SwiftUI
import CabalmailKit

/// Signed-in root.
///
/// The section layout (Mail / Addresses / Folders / Settings) branches on
/// horizontal size class:
///
/// - Compact (iPhone, iPad in narrow multitasking): a bottom `TabView`, one
///   tab per section. This is the natural compact idiom and the inner
///   `MailRootView` `NavigationSplitView` collapses to a stack here, so the
///   two never compete for the left edge.
/// - Regular (iPad / visionOS): just `MailRootView` — a single show/hide
///   sidebar owns the left edge, matching the macOS main window. Addresses /
///   Folders / Settings move into a modal `SettingsSheet`, opened by the
///   sidebar gear button or the ⌘, app command via
///   `AppState.settingsRequestTick`.
/// - macOS renders `MailRootView` directly and reaches the three sections
///   through its dedicated Settings scene (⌘,, `SettingsTabsView`).
///
/// The regular-width branch replaced an earlier `TabView(.sidebarAdaptable)`
/// that governed every iOS width. Its adaptive top-bar / sidebar chrome was
/// harmless on compact (it renders as a plain tab bar) but collided with
/// `MailRootView`'s own `NavigationSplitView` at regular width: the section
/// bar overlapped the split view's headers, and sidebar mode stacked two
/// redundant rails.
struct SignedInRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isOffline = false
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var settingsPresented = false
    #endif

    var body: some View {
        sectionLayout
            .overlay(alignment: .top) {
                statusBanners
                    .animation(.default, value: isOffline)
                    .animation(.default, value: appState.toast)
            }
            .task { await observeReachability() }
    }

    @ViewBuilder
    private var sectionLayout: some View {
        #if os(macOS)
        MailRootView()
        #else
        if horizontalSizeClass == .compact {
            compactTabs
        } else {
            MailRootView()
                .environment(\.showsSettingsGear, true)
                .sheet(isPresented: $settingsPresented) {
                    SettingsSheet()
                }
                // The gear button and the ⌘, command both bump the tick;
                // routing through it (rather than a direct binding) keeps the
                // trigger working regardless of which column holds focus.
                .onChange(of: appState.settingsRequestTick) { _, _ in
                    settingsPresented = true
                }
        }
        #endif
    }

    #if !os(macOS)
    /// Compact-width section switcher: a plain bottom tab bar. No
    /// `.sidebarAdaptable` - at compact width there's no sidebar to adapt to,
    /// and the regular-width path never renders this, so the adaptive style's
    /// collision with the inner split view can't recur.
    ///
    /// The Addresses / Folders tabs host the same `AddressListView` /
    /// `FolderListView` the Mail sidebar uses (wrapped in `AddressManagementTab`
    /// / `FolderManagementTab` for their own `NavigationStack` + selection).
    /// Those lists carry the full create/delete/request/revoke affordances, so
    /// there's a single list implementation per data type - the old dedicated
    /// management views were retired.
    private var compactTabs: some View {
        TabView {
            Tab("Mail", systemImage: "tray") {
                MailRootView()
            }
            Tab("Addresses", systemImage: "at") {
                AddressManagementTab()
            }
            Tab("Folders", systemImage: "folder") {
                FolderManagementTab()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
            // The search role detaches to the bottom-right, next to the tab bar.
            // On iOS 26 it adopts the morph (tab bar collapses to a dismiss
            // button, the button expands into a focused field); on iOS 18–25
            // it's a plain search tab. The morph itself comes from the
            // `.searchable` inside `SearchView`.
            Tab(role: .search) {
                SearchView()
            }
        }
    }
    #endif

    @ViewBuilder
    private var statusBanners: some View {
        VStack(spacing: 8) {
            if isOffline {
                BannerView(
                    icon: "wifi.slash",
                    text: "Offline — some actions will retry automatically.",
                    tint: .orange
                )
            }
            if let toast = appState.toast {
                ToastBanner(toast: toast, onCopy: copyHandler(for: toast))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 12)
    }

    /// Builds the banner's Copy action when the toast carries an address.
    /// Tapping it copies the address and replaces the banner with the shared
    /// "successfully copied" confirmation, so the post-creation Copy button
    /// and a list's copy action give identical feedback.
    private func copyHandler(for toast: Toast) -> (() -> Void)? {
        guard let address = toast.copyAddress else { return nil }
        return {
            copyToPasteboard(address)
            appState.showToast(.addressCopied(address), duration: 7)
        }
    }

    /// Mirrors `Reachability.isReachable` into view state. The kit side only
    /// exposes a stream — reading the stream with `for await` is the
    /// officially-supported way to observe NWPathMonitor transitions from
    /// Swift concurrency.
    private func observeReachability() async {
        #if canImport(Network)
        guard let reachability = appState.client?.reachability else { return }
        for await reachable in reachability.changes() {
            isOffline = !reachable
        }
        #endif
    }
}

#if !os(macOS)
/// Compact-iPhone Addresses tab: the shared `AddressListView` in its own
/// `NavigationStack`. Selection is local and inert here (there's no adjacent
/// message list to filter, as there is in the Mail sidebar) — the tab is a
/// management surface, and request/revoke/favorite/copy live on the rows.
private struct AddressManagementTab: View {
    @State private var selection: Address?

    var body: some View {
        NavigationStack {
            AddressListView(selection: $selection, externalFilter: nil)
        }
    }
}

/// Compact-iPhone Folders tab: the shared `FolderListView` in its own
/// `NavigationStack`. As with addresses, selection is local and inert — folder
/// browsing lives in the Mail tab; this tab owns create/delete/subscribe.
private struct FolderManagementTab: View {
    @State private var selection: Folder?

    var body: some View {
        NavigationStack {
            FolderListView(selection: $selection, externalFilter: nil)
        }
    }
}
#endif
