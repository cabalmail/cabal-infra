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
    private var compactTabs: some View {
        TabView {
            Tab("Mail", systemImage: "tray") {
                MailRootView()
            }
            Tab("Addresses", systemImage: "at") {
                AddressesView()
            }
            Tab("Folders", systemImage: "folder") {
                FoldersAdminView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
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
