import SwiftUI

/// A link the user primary-activated (click or tap) in the reader, parsed
/// from the `cabalLink` bridge payload (see `HTMLBodyView+LinkBridge`).
/// `rect` is the link's bounding box in the web view's coordinate space,
/// used to anchor the action popover at the link itself.
struct LinkMenuTarget: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// The link's visible text, whitespace-trimmed; empty for image-only
    /// links (the "Copy Link Text" action hides itself in that case).
    let text: String
    let rect: CGRect

    /// Schemes that never get a menu: they execute or read local state
    /// rather than navigate, so none of the menu's actions (copy aside)
    /// are safe or meaningful for them.
    private static let blockedSchemes: Set<String> = [
        "javascript", "vbscript", "data", "blob", "file", "about",
    ]

    /// True when a web view can render the destination — gates the
    /// "Open in Private Window" action.
    var isWebLink: Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    init?(bridgePayload payload: [String: Any]) {
        guard
            let href = payload["href"] as? String,
            let url = URL(string: href),
            let scheme = url.scheme?.lowercased(),
            !Self.blockedSchemes.contains(scheme)
        else { return nil }
        self.url = url
        self.text = ((payload["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // WKScriptMessage delivers JS numbers as NSNumber (integral when
        // the value happens to be whole), so go through NSNumber rather
        // than a direct Double cast.
        let originX = (payload["x"] as? NSNumber)?.doubleValue ?? 0
        let originY = (payload["y"] as? NSNumber)?.doubleValue ?? 0
        let width = (payload["w"] as? NSNumber)?.doubleValue ?? 0
        let height = (payload["h"] as? NSNumber)?.doubleValue ?? 0
        guard originX.isFinite, originY.isFinite, width.isFinite, height.isFinite else {
            return nil
        }
        self.rect = CGRect(x: originX, y: originY, width: width, height: height)
    }
}

/// Contents of the popover shown when the user primary-activates a link in
/// the reader: the destination URL up top (so the user can vet it before
/// acting), then the copy / open / share actions. Presentation and action
/// routing stay with the owner (`HTMLBodyView`); this view only reports
/// the choice — except Share, which is a `ShareLink` presenting the
/// system sheet itself (that's the point: browsers like Vivaldi expose
/// "open in private tab" as share-sheet actions, so the system sheet is
/// how private mode is reached without any Safari API existing for it).
struct LinkActionMenuView: View {
    enum Action {
        case copyText
        case copyAddress
        case open
    }

    let target: LinkMenuTarget
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.url.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(12)
            Divider()
            Group {
                if !target.text.isEmpty {
                    actionRow("Copy Link Text", systemImage: "textformat", action: .copyText)
                }
                actionRow("Copy Link Address", systemImage: "link", action: .copyAddress)
                actionRow(
                    target.isWebLink ? "Open in Browser" : "Open Link",
                    systemImage: "safari",
                    action: .open
                )
                ShareLink(item: target.url) {
                    rowLabel("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 240, maxWidth: 340)
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        action: Action
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            rowLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}
