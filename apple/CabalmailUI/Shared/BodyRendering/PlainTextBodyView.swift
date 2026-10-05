import SwiftUI

/// URLs and email addresses found in a plain-text body, ready to render.
/// `labels` maps each destination back to the text the user actually sees, so
/// the link menu can offer "Copy Link Text" when it differs from the address.
struct PlainTextLinks: Equatable {
    let attributed: AttributedString
    let labels: [URL: String]

    static let empty = PlainTextLinks(attributed: AttributedString(), labels: [:])
}

/// Linkifies plain-text bodies. A `text/plain` part carries no markup, so the
/// only way its URLs become actionable is to detect them: `NSDataDetector` is
/// the same machinery Mail and Messages use, and it already handles trailing
/// punctuation and bare `www.` hosts.
enum PlainTextLinkDetector {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Returns `plain` with `.link` runs (and link styling) over every detected
    /// URL. The character content is untouched — the reader's plain-text scroll
    /// restore reports exact content offsets, so the body must not reflow.
    static func scan(_ plain: String) -> PlainTextLinks {
        var attributed = AttributedString(plain)
        guard let detector else { return PlainTextLinks(attributed: attributed, labels: [:]) }
        let full = NSRange(plain.startIndex..., in: plain)
        var labels: [URL: String] = [:]
        for match in detector.matches(in: plain, range: full) {
            guard
                let url = match.url,
                let stringRange = Range(match.range, in: plain),
                let range = Range(stringRange, in: attributed)
            else { continue }
            attributed[range].link = url
            attributed[range].underlineStyle = .single
            labels[url] = String(plain[stringRange])
        }
        return PlainTextLinks(attributed: attributed, labels: labels)
    }

    /// Builds the menu target for a link the user activated in a plain-text
    /// body. The visible text of a detected link is usually the address itself;
    /// passing it through as the link text would give the menu two rows that
    /// copy the same string, so an identical label is reported as absent (the
    /// menu hides "Copy Link Text" for an empty one).
    static func menuTarget(for url: URL, labels: [URL: String]) -> LinkMenuTarget? {
        let label = labels[url] ?? ""
        let distinct = label == url.absoluteString ? "" : label
        return LinkMenuTarget(url: url, text: distinct)
    }
}

/// Plain-text body content: the message text with its URLs made tappable and
/// routed through the reader's link menu, so the plain path offers the same
/// actions as the HTML one (issue #765). Presentation lives here rather than in
/// `MessageDetailView` so the menu state travels with the body it belongs to.
struct PlainTextBodyView: View {
    let plain: String

    @State private var links: PlainTextLinks?
    @State private var linkMenu: LinkMenuTarget?
    /// Resolved from the ambient environment, above the override installed on
    /// the text below — the menu's "Open" action must reach the system opener,
    /// not bounce back into the menu.
    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState

    var body: some View {
        let scanned = links ?? PlainTextLinks.empty
        Text(links == nil ? AttributedString(plain) : scanned.attributed)
            .font(.body)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .environment(\.openURL, OpenURLAction { url in
                guard let target = PlainTextLinkDetector.menuTarget(
                    for: url,
                    labels: scanned.labels
                ) else { return .systemAction }
                linkMenu = target
                return .handled
            })
            .popover(item: $linkMenu) { target in
                LinkActionMenuView(target: target) { action in
                    handleMenuAction(action, for: target)
                }
                .presentationCompactAdaptation(.popover)
            }
            .task(id: plain) { links = PlainTextLinkDetector.scan(plain) }
    }

    private func handleMenuAction(_ action: LinkActionMenuView.Action, for target: LinkMenuTarget) {
        switch action {
        case .copyText:
            copyToPasteboard(target.text)
        case .copyAddress:
            copyToPasteboard(target.url.absoluteString)
        case .open:
            openURL(target.url)
        case .openPrivate:
            #if os(macOS)
            PrivateLinkHandoff.open(target.url, controlDomain: appState.controlDomain)
            #endif
        }
        linkMenu = nil
    }
}
