import SwiftUI
import CabalmailKit

// The reader's header block: subject, avatar, sender lines, and the message's
// metadata (date, sender authentication, custom flags). Lifted out of the main
// file to keep it under SwiftLint's file_length cap.
//
// Two layouts, chosen by `ReaderHeaderColumnPolicy` from the pane's width and
// nothing else — not the platform, the orientation, or the size class. A
// narrow pane stacks the metadata under the sender lines. A wide one sets it
// in a trailing column beside them, because a wide pane is often a short one
// (an iPhone in landscape) and every stacked row comes out of the body.

extension MessageDetailView {
    @ViewBuilder
    func headerBlock(paneWidth: CGFloat) -> some View {
        let usesTrailingColumn = ReaderHeaderColumnPolicy.usesTrailingColumn(
            paneWidth: paneWidth,
            minPaneWidth: headerTrailingColumnMinWidth
        )
        VStack(alignment: .leading, spacing: 8) {
            // Subject appears in full here because the list truncates it;
            // the surrounding ScrollView in `body` lets the header wrap
            // freely and scroll when needed.
            Text(envelope.subject ?? "(no subject)")
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 12) {
                if let apiClient = appState.client?.apiClient {
                    AvatarView(sender: envelope.from.first, apiClient: apiClient)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if usesTrailingColumn {
                        // Baseline-aligned so the date reads as part of the
                        // From line, the way a mail header usually sets it.
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                senderLines
                            }
                            Spacer(minLength: 0)
                            // Sized to its own content and measured first;
                            // the sender lines, which are what actually
                            // wrap, keep everything that's left.
                            VStack(alignment: .trailing, spacing: 4) {
                                metadataLines(
                                    showsAuthWarning: false,
                                    maxWidth: ReaderHeaderColumnPolicy
                                        .trailingColumnMaxWidth(paneWidth: paneWidth)
                                )
                            }
                            .layoutPriority(1)
                        }
                        // Full width under both columns: squeezed into the
                        // trailing one, the header's most important sentence
                        // would wrap to three or four lines.
                        AuthWarningLabel(results: envelope.authResults)
                    } else {
                        senderLines
                        metadataLines(showsAuthWarning: true, maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// From / To / Cc — the lines that wrap, so the ones that keep the width.
    @ViewBuilder
    private var senderLines: some View {
        if let from = envelope.from.first {
            Text(headerFromLabel(for: from))
                .font(.headline)
                .task(id: "\(from.mailbox.lowercased())@\(from.host.lowercased())") {
                    await hydrateSenderContactName(for: from)
                }
                .contextMenu { addressMenu(for: from) }
        }
        if !envelope.to.isEmpty {
            recipientFlow(label: "To:", addresses: envelope.to)
        }
        if !envelope.cc.isEmpty {
            recipientFlow(label: "Cc:", addresses: envelope.cc)
        }
    }

    /// Date, sender authentication, custom flags: stacked under the sender
    /// lines, or the trailing column's content.
    @ViewBuilder
    private func metadataLines(showsAuthWarning: Bool, maxWidth: CGFloat) -> some View {
        if let date = envelope.date ?? envelope.internalDate {
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        // Sender-authentication verdicts, rendered in all three states
        // ("Not verified" muted). Bucketing lives in CabalmailKit; see
        // `AuthResultsLine`.
        AuthResultsLine(results: envelope.authResults, showsWarning: showsAuthWarning)
        // Custom-flag chips (Phase 4): color dot + label per tagged palette
        // slot, live off the view model's optimistic set so the flag menu's
        // toggles reflect here instantly. A deleted slot's surviving tag
        // shows its slot id in gray, per the palette editor's
        // delete-confirmation copy.
        if let model, !model.keywordSlots.isEmpty {
            keywordChips(model: model, maxWidth: maxWidth)
        }
    }

    // A flow rather than an `HStack`: a message can carry up to twenty flags,
    // and the trailing column caps how wide they may run before wrapping.
    private func keywordChips(model: MessageDetailViewModel, maxWidth: CGFloat) -> some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4, maxLineWidth: maxWidth) {
            ForEach(FlagPalette.slots.filter { model.keywordSlots.contains($0) },
                    id: \.self) { slot in
                let entry = preferences.flagPalette.first { $0.slot == slot }
                HStack(spacing: 4) {
                    Circle()
                        .fill(FlagPaletteColor.color(for: entry?.color ?? ""))
                        .frame(width: 8, height: 8)
                    Text(entry?.label ?? slot)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}
