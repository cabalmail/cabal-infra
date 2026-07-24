import SwiftUI
@preconcurrency import WebKit

/// In-app private browsing for links opened from the reader.
///
/// Safari exposes no API for opening one of its private windows (its
/// scripting dictionary has no private-window support on macOS, and iOS
/// has nothing at all), so "Open in Private Window" renders the page in
/// an ephemeral in-app web view instead: non-persistent data store, no
/// cookies or history shared with anything, all state discarded when the
/// window closes. macOS, iPadOS, and visionOS get a real window (same
/// split as compose); iPhone falls back to a sheet.

/// Stable identifier for the private-browser `WindowGroup`, targeted by
/// `openWindow(id:value:)` from the reader's link menu.
let privateBrowserWindowID = "private-browser"

/// Whether this platform opens private browsing as its own window.
/// Same platform split as compose.
@MainActor
var privateBrowserOpensInWindow: Bool {
    composeOpensInWindow
}

/// `Identifiable` wrapper for the iPhone sheet path
/// (`.sheet(item:)` needs one; `URL` has no identity).
struct PrivateBrowserSheetTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// Private-browser scene group. Installed by both `CabalmailApp` and
/// `CabalmailMacApp` alongside the compose scene. Keyed by URL, so
/// opening a second link gets its own window while re-opening the same
/// link focuses the existing one.
struct PrivateBrowserWindowScene: Scene {
    var body: some Scene {
        WindowGroup("Private Browsing", id: privateBrowserWindowID, for: URL.self) { $url in
            if let url {
                PrivateBrowserView(url: url)
            } else {
                ContentUnavailableView("No page", systemImage: "eye.slash")
            }
        }
        // Never receive external URL events: mailto: routing must keep
        // landing on the compose scene (see CabalmailMacApp).
        .handlesExternalEvents(matching: [])
        #if os(macOS)
        // Private means private: don't bring the page back at relaunch
        // via state restoration (the ephemeral data store is gone anyway;
        // macOS-only — iOS has no scene-restoration behavior API).
        .restorationBehavior(.disabled)
        .defaultSize(width: 960, height: 720)
        #endif
    }
}

/// The browser chrome: back/forward, the current host as the title, an
/// escape hatch to the default browser, and (sheet path only) Done.
struct PrivateBrowserView: View {
    let url: URL

    @State private var model = PrivateBrowserModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            PrivateWebView(webView: model.webView)
                .navigationTitle(model.currentURL?.host() ?? "Private Browsing")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        .task { model.loadIfNeeded(url) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.webView.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            Button {
                model.webView.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openURL(model.currentURL ?? url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            if !privateBrowserOpensInWindow {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// Web-view state for one private-browsing session. The ephemeral
/// `WKWebsiteDataStore` is created per instance, so closing the window
/// discards every cookie and cache entry with it. Page JavaScript stays
/// enabled here — this is a user-initiated browsing context, unlike the
/// reader.
@MainActor
@Observable
final class PrivateBrowserModel: NSObject {
    let webView: WKWebView
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var currentURL: URL?
    private var didLoad = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Idempotent first load — `.task` re-runs if the hosting view is
    /// re-attached, and reloading would blow away navigation history.
    func loadIfNeeded(_ url: URL) {
        guard !didLoad else { return }
        didLoad = true
        webView.load(URLRequest(url: url))
    }

    private func sync() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }
}

extension PrivateBrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        sync()
    }
}

extension PrivateBrowserModel: WKUIDelegate {
    /// `target="_blank"` links ask for a new web view; route them into
    /// this one instead so they aren't silently dead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// Minimal representable hosting the model's `WKWebView`. The model owns
/// the view (not the other way around) so navigation state survives
/// SwiftUI re-layouts.
private struct PrivateWebView {
    let webView: WKWebView
}

#if os(macOS)
extension PrivateWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension PrivateWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
