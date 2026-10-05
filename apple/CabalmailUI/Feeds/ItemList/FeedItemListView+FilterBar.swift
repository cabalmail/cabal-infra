import SwiftUI
import CabalmailKit

// The bar above the feed item list: the All / Unread / Flagged pills, the
// ordering menu and search field for a single feed, and the status lines. A
// sibling extension so the primary FeedItemListView body stays under
// SwiftLint's `type_body_length` cap, like `+Footer`.
extension FeedItemListView {
    @ViewBuilder
    func filterBar(_ model: FeedItemListViewModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(RssItemFilter.allCases) { filter in
                    Button {
                        model.selectFilter(filter)
                    } label: {
                        Text(filterLabel(filter))
                            .font(.subheadline.weight(model.filter == filter ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                model.filter == filter ? ColorTokens.accentForestFg.opacity(0.18) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed.filter.\(filter.rawValue)")
                }
                Spacer()
                if model.canSearch {
                    Menu {
                        // A `Picker` inside a `Menu` renders as a submenu on
                        // macOS, which put all four orderings one level down
                        // behind an "Order" row (#1508). Inline, they are the
                        // menu's own rows, the way the Sort menu reads. An
                        // inline picker still draws its title as a section
                        // header, repeating the word on the button just
                        // pressed, so the label is hidden (VoiceOver keeps it).
                        Picker("Order", selection: $model.ordering) {
                            Text("Newest first").tag(RssOrderingMode.newestFirst)
                            Text("Oldest first").tag(RssOrderingMode.oldestFirst)
                            Text("Newest day, oldest first within").tag(RssOrderingMode.newestDayOldestWithin)
                            Text("Oldest day, newest first within").tag(RssOrderingMode.oldestDayNewestWithin)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .accessibilityLabel("Order")
                    }
                    .accessibilityIdentifier("feed.order")
                    .onChange(of: model.ordering) { _, _ in Task { await model.reload() } }
                }
            }
            if model.canSearch {
                TextField("Search this feed", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("feed.search")
            }
            statusLines(model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// The sync error, then the fetcher's health for a single feed in its
    /// own words, so an empty or stale list is explained where the user is
    /// looking.
    @ViewBuilder
    func statusLines(_ model: FeedItemListViewModel) -> some View {
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(ColorTokens.dangerFg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let subscription = model.subscription, let headline = FeedHealth.headline(for: subscription.feed) {
            let stopped = FeedHealth.level(for: subscription.feed) == .stopped
            Label(headline, systemImage: stopped ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(stopped ? ColorTokens.dangerFg : ColorTokens.warningFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("feed.health.headline")
        }
    }

    func filterLabel(_ filter: RssItemFilter) -> String {
        switch filter {
        case .all: return "All"
        case .unread: return "Unread"
        // Mail's word for the same mark (cross-media plan, decision 3); the
        // wire value stays `favorite`.
        case .favorite: return "Flagged"
        }
    }
}
