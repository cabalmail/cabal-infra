import Foundation
@preconcurrency import WebKit
#if canImport(AppKit)
import AppKit
#endif

/// Owns the WKWebView that backs the rich-text composer surface, exposing an
/// async Swift API around the JS bridge defined in `editor-bridge.js`.
///
/// The same WebView is the editor *and* the marked/turndown sandbox: a
/// Markdown-only compose call still goes through this controller, because the
/// only way to guarantee byte-for-byte parity with the React composer is to
/// run the same JS libraries against the same inputs. `ComposeViewModel`
/// constructs one controller per draft and tears it down on dismiss.
///
/// Threading: marked `@MainActor` because WKWebView API contracts require the
/// main thread; bridge callbacks are dispatched on main as well. Swift 6
/// strict concurrency is satisfied by the `@preconcurrency import WebKit`
/// (WebKit has not adopted Sendable conformances yet) plus the per-method
/// `@MainActor` guarantee.
/// Text-alignment value carried in `RichTextEditorController.Selection`.
/// Lifted out of `Selection` so it can be referenced by the SwiftUI toolbar
/// without nesting two levels deep (SwiftLint's `nesting` rule).
public enum RichTextAlignment: String, Sendable { case left, center, right }

@MainActor
public final class RichTextEditorController: NSObject {
    /// Snapshot of the toolbar-relevant state of the editor's current
    /// selection. Posted by `editor-bridge.js` after every input or
    /// selection change so SwiftUI can paint the toolbar.
    public struct Selection: Equatable, Sendable {
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        public var bulletList: Bool
        public var orderedList: Bool
        /// 0 when the selection is not inside a heading; otherwise the
        /// heading level (1-6).
        public var headingLevel: Int
        public var alignment: RichTextAlignment
        public var link: Bool
        public var canUndo: Bool
        public var canRedo: Bool

        public init(
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            strikethrough: Bool = false,
            bulletList: Bool = false,
            orderedList: Bool = false,
            headingLevel: Int = 0,
            alignment: RichTextAlignment = .left,
            link: Bool = false,
            canUndo: Bool = false,
            canRedo: Bool = false
        ) {
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.bulletList = bulletList
            self.orderedList = orderedList
            self.headingLevel = headingLevel
            self.alignment = alignment
            self.link = link
            self.canUndo = canUndo
            self.canRedo = canRedo
        }
    }

    public enum Command: Sendable {
        case bold, italic, underline, strikethrough
        case bulletList, orderedList
        case alignLeft, alignCenter, alignRight
        /// Pass 0 to toggle the current heading back to a paragraph.
        case heading(level: Int)
        case horizontalRule
        case createLink(url: String)
        case unlink
        case undo, redo

        /// Bridge payload: the JS exec name plus any extra argument the
        /// command carries. Centralized here so the controller's `execute`
        /// stays a straight pass-through and SwiftLint doesn't trip on a
        /// 15-case switch in the actor surface.
        fileprivate var payload: (name: String, extras: [Any]) {
            switch self {
            case .bold: return ("bold", [])
            case .italic: return ("italic", [])
            case .underline: return ("underline", [])
            case .strikethrough: return ("strikethrough", [])
            case .bulletList: return ("bulletList", [])
            case .orderedList: return ("orderedList", [])
            case .alignLeft: return ("alignLeft", [])
            case .alignCenter: return ("alignCenter", [])
            case .alignRight: return ("alignRight", [])
            case .heading(let level): return ("heading", [level])
            case .horizontalRule: return ("horizontalRule", [])
            case .createLink(let url): return ("createLink", [url])
            case .unlink: return ("unlink", [])
            case .undo: return ("undo", [])
            case .redo: return ("redo", [])
            }
        }
    }

    public let webView: WKWebView

    /// Latest selection snapshot. Mutated on the main actor by the JS bridge
    /// callback; observers should re-read it after `onSelectionChanged`.
    public private(set) var selection: Selection = .init()
    /// True once `editor-bridge.js` has finished bootstrapping and is safe
    /// to call. Drives `waitUntilReady()` so callers don't race the load.
    public private(set) var isReady: Bool = false

    /// Fires after every `input` event from the editor (typing, paste,
    /// formatting). Use it to invalidate cached HTML.
    public var onContentChanged: (@MainActor () -> Void)?
    /// Fires after a selection change inside the editor surface. The
    /// updated `selection` is already in place when this runs.
    public var onSelectionChanged: (@MainActor (Selection) -> Void)?
    /// Fires once after the editor finishes bootstrapping.
    public var onReady: (@MainActor () -> Void)?

    private var pendingReadyContinuations: [CheckedContinuation<Void, Never>] = []

    public init(placeholder: String? = nil) {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsLinkPreview = false
        #if os(iOS) || os(visionOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        self.webView = webView
        super.init()
        controller.add(BridgeRelay(target: self), name: "cabal")
        webView.navigationDelegate = self

        // `.copy("Compose/Resources")` lands the folder in the bundle as
        // "Resources/". Fall back to a flat root lookup so a future
        // restructure of Package.swift (per-file `.copy`s) keeps working.
        let url = Bundle.module.url(
            forResource: "editor",
            withExtension: "html",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "editor", withExtension: "html")

        guard let editorUrl = url else {
            assertionFailure("editor.html not present in CabalmailKit bundle")
            return
        }
        webView.loadFileURL(editorUrl, allowingReadAccessTo: editorUrl.deletingLastPathComponent())

        if let placeholder, !placeholder.isEmpty {
            Task { @MainActor in
                await waitUntilReady()
                await call("setPlaceholder", args: [placeholder])
            }
        }
    }

    /// Suspends the caller until the bridge has posted its `ready` message.
    /// Cheap to call repeatedly — returns immediately once ready.
    public func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingReadyContinuations.append(continuation)
        }
    }

    // MARK: - Editor state

    public func setHTML(_ html: String) async {
        await waitUntilReady()
        await call("setHTML", args: [html])
    }

    public func getHTML() async -> String {
        await waitUntilReady()
        let value = await callString("getHTML")
        return value ?? ""
    }

    public func isEmpty() async -> Bool {
        await waitUntilReady()
        let value = await callBool("isEmpty")
        return value ?? true
    }

    public func focus() async {
        await waitUntilReady()
        await call("focus")
    }

    /// Focuses the editor with the caret positioned at the start of the
    /// document. Used on reply / reply-all so the cursor lands above the
    /// seeded separator + attribution + quoted original.
    ///
    /// On macOS the WKWebView must be its window's first responder for
    /// the inner contenteditable to receive keyboard input — a bare JS
    /// `editor.focus()` only moves DOM focus, which is why earlier
    /// versions left the SwiftUI Form's first text field (To) holding
    /// the AppKit first-responder slot. Make the webview first responder
    /// before bouncing into JS.
    public func focusAtStart() async {
        await waitUntilReady()
        #if canImport(AppKit)
        if let window = webView.window {
            window.makeFirstResponder(webView)
        }
        #endif
        await call("focusAtStart")
    }

    // MARK: - Conversions (parity with React)

    public func markdownToHtml(_ markdown: String) async -> String {
        await waitUntilReady()
        let value = await callString("markdownToHtml", args: [markdown])
        return value ?? ""
    }

    public func htmlToMarkdown(_ html: String) async -> String {
        await waitUntilReady()
        let value = await callString("htmlToMarkdown", args: [html])
        return value ?? ""
    }

    public func styleParagraphs(_ html: String) async -> String {
        await waitUntilReady()
        let value = await callString("styleParagraphs", args: [html])
        return value ?? html
    }

    // MARK: - Commands

    public func execute(_ command: Command) async {
        await waitUntilReady()
        let payload = command.payload
        await call("exec", args: [payload.name] + payload.extras)
    }

    // MARK: - Bridge plumbing

    fileprivate func handleBridgeMessage(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            guard !isReady else { return }
            isReady = true
            let waiters = pendingReadyContinuations
            pendingReadyContinuations.removeAll()
            for continuation in waiters { continuation.resume() }
            onReady?()
        case "input":
            onContentChanged?()
        case "selection":
            if let states = payload["states"] as? [String: Any] {
                selection = Selection(states: states)
                onSelectionChanged?(selection)
            }
        default:
            break
        }
    }

    // The WKWebView async/await API can throw on otherwise-benign navigations
    // (e.g. mid-call frame teardown). Conversions and commands aren't worth
    // surfacing errors for — they fall back to an empty / identity result.
    private func call(_ method: String, args: [Any] = []) async {
        let script = "window.cabal.\(method)(\(encode(args)));"
        _ = try? await webView.evaluateJavaScript(script)
    }

    private func callString(_ method: String, args: [Any] = []) async -> String? {
        let script = "window.cabal.\(method)(\(encode(args)));"
        return (try? await webView.evaluateJavaScript(script)) as? String
    }

    private func callBool(_ method: String, args: [Any] = []) async -> Bool? {
        let script = "window.cabal.\(method)(\(encode(args)));"
        return (try? await webView.evaluateJavaScript(script)) as? Bool
    }

    private func encode(_ args: [Any]) -> String {
        args.map { encodeArgument($0) }.joined(separator: ",")
    }

    private func encodeArgument(_ value: Any) -> String {
        if let int = value as? Int { return String(int) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let string = value as? String {
            let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(json.dropFirst().dropLast())
        }
        return "null"
    }
}

// MARK: - WKNavigationDelegate

extension RichTextEditorController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only allow the initial file:// load of editor.html. Any link click
        // (or window.location assignment) escapes to the user's default
        // browser via the host app, not inside the composer surface.
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.isFileURL == true {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }
}

// MARK: - Bridge relay

/// Bridges WKScriptMessage delivery (which holds a strong reference to its
/// handler) to a weak reference on the controller so the controller can be
/// torn down without keeping its webview alive.
private final class BridgeRelay: NSObject, WKScriptMessageHandler {
    private weak var target: RichTextEditorController?
    init(target: RichTextEditorController) {
        self.target = target
    }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any] else { return }
        let target = self.target
        Task { @MainActor in
            target?.handleBridgeMessage(payload)
        }
    }
}

// MARK: - Selection bridge

extension RichTextEditorController.Selection {
    fileprivate init(states: [String: Any]) {
        self.init()
        bold = states["bold"] as? Bool ?? false
        italic = states["italic"] as? Bool ?? false
        underline = states["underline"] as? Bool ?? false
        strikethrough = states["strikethrough"] as? Bool ?? false
        bulletList = states["bulletList"] as? Bool ?? false
        orderedList = states["orderedList"] as? Bool ?? false
        headingLevel = states["headingLevel"] as? Int ?? 0
        if let raw = states["alignment"] as? String,
           let parsed = RichTextAlignment(rawValue: raw) {
            alignment = parsed
        }
        link = states["link"] as? Bool ?? false
        canUndo = states["canUndo"] as? Bool ?? false
        canRedo = states["canRedo"] as? Bool ?? false
    }
}
