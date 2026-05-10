import SwiftUI
import CabalmailKit

/// Signed-in tab root — Mail / Addresses / Folders / Settings.
///
/// iOS, iPadOS, and visionOS use a SwiftUI 18 `TabView` with the
/// `.sidebarAdaptable` style so iPhone gets a tab bar while iPad /
/// visionOS get a sidebar that collapses in compact trait environments.
/// macOS uses a custom segmented `Picker` pinned in a window-centered
/// header bar instead, for two reasons:
///   1. `.sidebarAdaptable` on macOS would render a second sidebar
///      stacked next to `MailRootView`'s folder sidebar; SwiftUI's
///      column distribution couldn't handle that and crushed the
///      message list (#385).
///   2. TabView's default macOS style puts the tabs in the toolbar's
///      principal slot, which is centered between the leading and
///      trailing toolbar items — so when the trailing items differ
///      between tabs (Compose lives only on Mail), the chooser
///      visibly shifts left/right as the user switches sections.
/// The header-bar Picker is window-centered via `Spacer / Picker /
/// Spacer` and stays put as the user navigates. The Settings tab is
/// still hidden on macOS because `CabalmailMacApp` already wires the
/// Settings scene to ⌘,.
struct SignedInRootView: View {
    enum Section: Hashable {
        case mail
        case addresses
        case folders
        case settings
    }

    @State private var selected: Section = .mail
    @Environment(AppState.self) private var appState
    @State private var isOffline = false

    var body: some View {
        platformBody
            .overlay(alignment: .top) {
                statusBanners
                    .animation(.default, value: isOffline)
                    .animation(.default, value: appState.toast)
            }
            .task { await observeReachability() }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("Section", selection: $selected) {
                    Label("Mail", systemImage: "tray").tag(Section.mail)
                    Label("Addresses", systemImage: "at").tag(Section.addresses)
                    Label("Folders", systemImage: "folder").tag(Section.folders)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .frame(height: 38)
            .background(.regularMaterial)
            Divider()
            sectionContent
        }
        #else
        TabView(selection: $selected) {
            Tab("Mail", systemImage: "tray", value: Section.mail) {
                MailRootView()
            }
            Tab("Addresses", systemImage: "at", value: Section.addresses) {
                AddressesView()
            }
            Tab("Folders", systemImage: "folder", value: Section.folders) {
                FoldersAdminView()
            }
            Tab("Settings", systemImage: "gear", value: Section.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #endif
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selected {
        case .mail:      MailRootView()
        case .addresses: AddressesView()
        case .folders:   FoldersAdminView()
        case .settings:  EmptyView()
        }
    }

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
                BannerView(
                    icon: icon(for: toast.kind),
                    text: toast.message,
                    tint: tint(for: toast.kind)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 12)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "tray.and.arrow.up.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for kind: Toast.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
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

private struct BannerView: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
    }
}
