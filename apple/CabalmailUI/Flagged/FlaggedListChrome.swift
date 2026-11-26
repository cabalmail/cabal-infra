import SwiftUI
import CabalmailKit

/// The Flagged view's words: the lines above and below its list. Pure, so
/// each is tested without a view.
enum FlaggedListWords {
    static let truncated = "More than 5,000 flagged messages. Some are not listed."
    static let coverage = "Mail from subscribed folders. Trash is not included."
    static let nextPageFailed = "More flagged mail could not be loaded."
    static let loadingMore = "Loading more…"

    /// The line for a mail half that has nothing new to show. With no page
    /// ever loaded the list holds feed items only, and says so; offline,
    /// it says why.
    static func mailFailure(_ failure: FlaggedMailFailure, isOffline: Bool) -> String {
        switch failure {
        case .neverLoaded:
            return (isOffline ? "Flagged mail needs a connection." : "Flagged mail could not be loaded.")
                + " Showing flagged feed items only."
        case .refresh:
            return "Flagged mail could not be refreshed. Showing it as it was last loaded."
        case .nextPage:
            return nextPageFailed
        }
    }

    /// The empty list's title: what was looked for and not found.
    static func emptyTitle(for criterion: FlagCriterion, palette: [FlagPaletteEntry]) -> String {
        criterion == .any
            ? "No flagged items"
            : "No items marked \(FlagFilterMenuPolicy.name(of: criterion, palette: palette))"
    }

    static func emptyDescription(for criterion: FlagCriterion) -> String {
        criterion == .any
            ? "Flag a message or a feed item and it is listed here."
            : "No message and no feed item carries this flag."
    }
}

/// The bar above the Flagged list: the flag pill, once there is a flag to
/// pick, and the lines that say what the list is missing.
struct FlaggedListBar: View {
    let model: FlaggedListViewModel
    /// Whether the device has no connection, for the failure line's words.
    let isOffline: Bool

    var body: some View {
        let failure = model.mailFailure.flatMap { $0 == .nextPage ? nil : $0 }
        if model.pill != nil || model.truncated || failure != nil || model.errorMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let pill = model.pill {
                    HStack(spacing: 6) {
                        FlagFilterPill(pill: pill, identifier: "flagged.filter.flag") { model.choose($0) }
                        Spacer()
                    }
                }
                if model.truncated {
                    notice(FlaggedListWords.truncated, identifier: "flagged.notice.truncated")
                }
                if let failure {
                    HStack(alignment: .firstTextBaseline) {
                        notice(
                            FlaggedListWords.mailFailure(failure, isOffline: isOffline),
                            identifier: "flagged.notice.mail"
                        )
                        Spacer()
                        Button("Retry") { model.retryMail() }
                            .disabled(model.mailLoading)
                            .accessibilityIdentifier("flagged.retry")
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .appFont(.footnote)
                        .foregroundStyle(ColorTokens.dangerFg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func notice(_ text: String, identifier: String) -> some View {
        Text(text)
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

/// The Flagged list's last row: the row that asks for the next page while
/// the list ends at its horizon, the empty words, or what the list covers.
struct FlaggedListFooter: View {
    let model: FlaggedListViewModel
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Group {
            if model.mailFailure == .nextPage {
                HStack {
                    Text(FlaggedListWords.nextPageFailed)
                    Spacer()
                    Button("Retry") { model.retryMail() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("flagged.retryMore")
                }
            } else if model.page.next != nil || model.mailLoading || !model.feedLoaded {
                // The list ends at its horizon, or nothing has landed yet.
                HStack(spacing: 8) {
                    ProgressView()
                    Text(FlaggedListWords.loadingMore)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .onAppear { model.footer(isVisible: true) }
                .onDisappear { model.footer(isVisible: false) }
                .accessibilityIdentifier("flagged.loadingMore")
            } else if model.isEmpty {
                ContentUnavailableView(
                    FlaggedListWords.emptyTitle(for: model.criterion, palette: preferences.flagPalette),
                    systemImage: "flag",
                    description: Text(FlaggedListWords.emptyDescription(for: model.criterion))
                )
            } else if model.mailFailure == nil {
                Text(FlaggedListWords.coverage)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("flagged.coverage")
            }
        }
        .appFont(.footnote)
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    }
}
