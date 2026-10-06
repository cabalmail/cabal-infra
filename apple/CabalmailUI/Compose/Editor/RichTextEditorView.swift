import SwiftUI
import CabalmailKit
@preconcurrency import WebKit

/// SwiftUI surface for a `RichTextEditorController`-owned `WKWebView`.
///
/// The controller owns the lifecycle (load, JS bridge, async API) so we can
/// reach into it from `ComposeViewModel` without going through the view layer.
/// This view's only job is to mount the controller's pre-built `WKWebView`
/// into the SwiftUI tree. It deliberately doesn't make a fresh `WKWebView` —
/// recreating one per `body` re-evaluation would blow the editor's contents
/// away and re-bootstrap the JS bridge.
struct RichTextEditorView: View {
    let controller: RichTextEditorController

    var body: some View {
        #if os(macOS)
        MacRichTextWebView(webView: controller.webView)
        #else
        MobileRichTextWebView(webView: controller.webView)
        #endif
    }
}

#if os(iOS) || os(visionOS)
private struct MobileRichTextWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The controller owns mutable editor state; nothing to push here.
    }
}
#endif

#if os(macOS)
private struct MacRichTextWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The controller owns mutable editor state; nothing to push here.
    }
}
#endif
