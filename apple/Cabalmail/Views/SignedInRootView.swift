import SwiftUI
import CabalmailKit

/// Signed-in tab root — Mail / Addresses / Folders / Settings.
///
/// Uses the SwiftUI 18 `TabView(selection:)` + `Tab { … }` surface with the
/// `.sidebarAdaptable` style so iPhone gets a tab bar, iPad / visionOS get
/// a sidebar that collapses to a tab bar in compact trait environments,
/// and macOS shows a sidebar by default. The Settings tab is hidden on
/// macOS because the Settings scene wired to ⌘, in `CabalmailMacApp`
/// already covers that ground per the plan.
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
            #if !os(macOS)
            Tab("Settings", systemImage: "gear", value: Section.settings) {
                SettingsView()
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .top) {
            statusBanners
                .animation(.default, value: isOffline)
                .animation(.default, value: appState.toast)
        }
        .task { await observeReachability() }
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

    private func icon(for kind: AppState.Toast.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "tray.and.arrow.up.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for kind: AppState.Toast.Kind) -> Color {
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
