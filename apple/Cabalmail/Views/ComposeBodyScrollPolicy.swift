/// Who scrolls the compose form's body editor clear of the keyboard.
///
/// Nobody did, on iPhone. The body is a `WKWebView`, and web-content focus
/// is invisible to SwiftUI's focus system — SwiftUI scrolls a focused
/// *native* control into view, never the editor — so focusing the body left
/// the grouped `Form` roughly where it was and the keyboard plus its
/// input-accessory bar covered the Rich Text / Markdown picker, the whole
/// formatting toolbar and every character typed. The message was composed
/// blind (#1370).
///
/// UIKit's own scroll-to-first-responder used to paper over it by scrolling
/// ancestor scroll views for the web view. It is not something to rely on:
/// measured on the iPhone 16 Pro sim, the editor sat at y=706 on iOS 26 and
/// entirely off screen on iOS 27, against a keyboard whose top was ~524.
/// So the form scrolls the editor into view itself, off the two signals it
/// does get — the editor's DOM-focus callback, and the keyboard appearing
/// afterwards (`ComposeView.composeForm`). Both are needed: whichever
/// happens second is the one that can act against a settled layout.
enum ComposeBodyScrollPolicy {

    /// Identity of the row the form scrolls to. Deliberately its own value
    /// rather than the `.message` section's `ForEach` identity, so
    /// `scrollTo` has exactly one target to resolve.
    static let bodyScrollTarget = "compose.body.scrollTarget"

    /// True where the compose form has to scroll the body editor into view
    /// itself.
    ///
    /// iPhone and iPad only. macOS lays the editor out below a fixed header
    /// with no keyboard inset at all (`ComposeView.macLayout`), and
    /// visionOS floats its keyboard outside the window rather than insetting
    /// the scene, so neither has the problem to fix.
    static func appMustScrollBodyIntoView(on platform: HostPlatform) -> Bool {
        platform == .iOS
    }

    /// The running platform's answer.
    static var appMustScrollBodyIntoView: Bool {
        appMustScrollBodyIntoView(on: .current)
    }
}
