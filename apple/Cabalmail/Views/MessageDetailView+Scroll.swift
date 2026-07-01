import SwiftUI
import CabalmailKit

// In-message scroll capture and restore, split out of `MessageDetailView` to
// keep that file under SwiftLint's file-length cap (matching the `+Toolbar` /
// `+Compose` sibling pattern). The nav cursor carries an exact content offset
// for plain-text bodies (`messageScroll`) and a reflow-robust DOM anchor for
// HTML bodies (`messageAnchor`); the reader consumes whichever matches the body
// it rendered, and streams the live position back as the user reads.
extension MessageDetailView {
    /// The body region: spinner, HTML/plain renderer, or error/empty state.
    /// Lives here (not in the main struct) so `MessageDetailView` stays under
    /// SwiftLint's type-body cap after the scroll wiring.
    @ViewBuilder
    func body(for model: MessageDetailViewModel) -> some View {
        // Spinner wins over the error/retry screen whenever a load is in
        // flight, and whenever the view hasn't completed an attempt yet. A
        // fast-failing fetch used to paint the red banner before the user
        // saw any indication of work — issue #403.
        if model.isLoading || !model.hasAttemptedLoad {
            ProgressView("Fetching message…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let html = model.htmlBody, !model.forcePlainText {
            htmlBodyView(html: html, model: model)
        } else if let plain = model.plainText {
            plainBodyView(plain)
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No renderable body.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    /// HTML body. WKWebView manages its own scrolling; `restoreAnchor` reapplies
    /// a resumed scroll position once the body loads, and `onScrollCaptured`
    /// streams the live position back to the cursor.
    @ViewBuilder
    private func htmlBodyView(html: String, model: MessageDetailViewModel) -> some View {
        HTMLBodyView(
            html: html,
            inlineImages: model.inlineImages,
            allowRemote: model.remoteContentAllowed,
            readerMode: model.readerMode,
            printRequestTick: model.printRequestTick,
            restoreAnchor: restoreScrollAnchor,
            onScrollCaptured: { anchor in reportMessageScroll(offset: nil, anchor: anchor) }
        )
    }

    /// Plain-text body. It doesn't reflow, so an exact content offset
    /// round-trips: bind the scroll position for restore, capture reads back.
    @ViewBuilder
    private func plainBodyView(_ plain: String) -> some View {
        ScrollView {
            Text(plain)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollPosition($plainScrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            reportPlainScroll(offset)
        }
        .onChange(of: restoreScrollOffset) { _, offset in
            if let offset { plainScrollPosition.scrollTo(y: CGFloat(offset)) }
        }
        .onAppear {
            if let offset = restoreScrollOffset {
                plainScrollPosition.scrollTo(y: CGFloat(offset))
            }
        }
    }

    /// Pulls a pending scroll restore off the nav coordinator once the body is
    /// available, matched to this exact message. Runs at most once per message
    /// (`didConsumeScrollRestore`); a normal open finds nothing pending and
    /// leaves the reader at the top.
    func consumeScrollRestoreIfReady() {
        guard !didConsumeScrollRestore, let model else { return }
        guard model.htmlBody != nil || model.plainText != nil else { return }
        didConsumeScrollRestore = true
        guard let restore = appState.navCoordinator?.consumeScrollRestore(
            folderPath: folder.path,
            uid: envelope.uid,
            messageID: envelope.messageId
        ) else { return }
        restoreScrollAnchor = restore.anchor
        restoreScrollOffset = restore.offset
    }

    /// Relays the current in-message scroll position to the nav cursor. `offset`
    /// is set for plain text, `anchor` for HTML; the coordinator debounces and
    /// only writes on change, and ignores it unless the cursor is still on this
    /// message.
    func reportMessageScroll(offset: Int?, anchor: String?) {
        appState.navCoordinator?.recordMessageScroll(
            folderPath: folder.path,
            uid: envelope.uid,
            offset: offset,
            anchor: anchor
        )
    }

    /// Throttled plain-text scroll reporter: `onScrollGeometryChange` fires
    /// densely during a drag, so skip sub-8pt deltas to avoid churning the save
    /// debounce.
    func reportPlainScroll(_ offsetY: CGFloat) {
        let offset = max(0, Int(offsetY))
        if abs(offset - lastReportedPlainOffset) < 8 { return }
        lastReportedPlainOffset = offset
        reportMessageScroll(offset: offset, anchor: nil)
    }
}
