import SwiftUI

#if os(iOS)
import Observation
import UIKit

/// Captures the tab in front as the phone's Search tab opens, for the Search
/// tab to show until a search runs (`SearchBackdrop`).
///
/// One per `TabShell`, which mounts `windowReader` so the capture knows its
/// window: an iPad can have several, and the key window isn't necessarily the
/// one whose bar was tapped.
@Observable
@MainActor
final class SearchBackdropCapture {
    /// The window `TabShell` is in, kept current by `windowReader`.
    @ObservationIgnored fileprivate weak var window: UIWindow?
    /// That window's size, which a capture has to match to be shown
    /// (`SearchBackdrop.fits`). Read from the window rather than measured in
    /// SwiftUI, where a full-bleed frame still shrinks with the keyboard.
    private(set) var windowSize: CGSize?

    /// An empty view for `TabShell`'s background that tells this capture its
    /// window, and the window's size as it changes.
    var windowReader: some View { BackdropWindowReader(capture: self) }

    /// The window's last drawn frame, above its tab bar, and the window's
    /// size; nil with no window or bar to measure, or nothing drawn.
    ///
    /// Called from the tab bar's selection setter, which UIKit calls after
    /// it has already put the Search tab's view in place of the outgoing
    /// tab's, so the outgoing tab's view is out of the window and can't be
    /// drawn itself. `drawHierarchy(afterScreenUpdates: false)` draws what
    /// the screen last showed instead — the outgoing tab, its glass and its
    /// scroll edge included. The clip leaves out the tab bar's band, where
    /// the collapsed bar and the field take the bar's place.
    func capture() -> (image: UIImage, size: CGSize)? {
        guard let window, let tabBar = Self.tabBar(in: window.rootViewController) else { return nil }
        let bounds = window.bounds
        let barTop = tabBar.convert(tabBar.bounds, to: window).minY
        let renderer = UIGraphicsImageRenderer(
            bounds: bounds,
            format: UIGraphicsImageRendererFormat(for: window.traitCollection)
        )
        var drawn = false
        let image = renderer.image { context in
            context.cgContext.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: barTop))
            drawn = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return drawn ? (image, bounds.size) : nil
    }

    /// The reader moved to `window`, or laid out in it.
    fileprivate func read(_ window: UIWindow?) {
        self.window = window
        let size = window?.bounds.size
        if size != windowSize { windowSize = size }
    }

    /// The tab bar of the first tab bar controller under `controller`: the
    /// one `TabShell`'s `TabView` is drawn with.
    private static func tabBar(in controller: UIViewController?) -> UITabBar? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs.tabBar }
        for child in controller.children {
            if let found = tabBar(in: child) { return found }
        }
        return tabBar(in: controller.presentedViewController)
    }
}

/// Hands its window to a `SearchBackdropCapture` whenever it moves to one.
private struct BackdropWindowReader: UIViewRepresentable {
    let capture: SearchBackdropCapture

    func makeUIView(context: Context) -> BackdropWindowReaderView {
        let view = BackdropWindowReaderView()
        view.isUserInteractionEnabled = false
        view.capture = capture
        return view
    }

    func updateUIView(_ uiView: BackdropWindowReaderView, context: Context) {
        uiView.capture = capture
    }
}

/// Lays out with `TabShell`'s tree, so a rotation or a window resize reaches
/// it.
private final class BackdropWindowReaderView: UIView {
    weak var capture: SearchBackdropCapture?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        capture?.read(window)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capture?.read(window)
    }
}
#endif
