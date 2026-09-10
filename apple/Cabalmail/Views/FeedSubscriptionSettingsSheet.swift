import SwiftUI
import CabalmailKit

/// Per-subscription settings: title, folder, the ordering and the reader's
/// first view (open mode, styling), the feed's health as the fetcher last
/// saw it, and Unsubscribe. Save sends only what changed.
struct FeedSubscriptionSettingsSheet: View {
    let subscription: RssSubscription
    @Bindable var form: FeedSubscriptionSettingsForm
    let folders: [RssFolder]
    let management: FeedManagementViewModel
    let onSaved: (RssSubscription) -> Void
    let onUnsubscribed: (RssSubscription) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var confirmUnsubscribe = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(subscription.displayTitle)
                #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if management.isBusy { ProgressView() } else { Text("Save") }
                        }
                        .disabled(form.update(against: subscription) == nil || management.isBusy)
                        .accessibilityIdentifier("feed.settings.save")
                    }
                }
                .confirmationDialog("Unsubscribe from \(subscription.displayTitle)?",
                                    isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
                    Button("Unsubscribe", role: .destructive) { Task { await unsubscribe() } }
                } message: {
                    Text("Its items and your read and favorite marks for it are removed from this account.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ScrollView {
            MacSheetForm {
                MacSheetSection(caption: "Title") { titleField.textFieldStyle(.roundedBorder) }
                MacSheetSection(caption: "Folder") { folderPicker.labelsHidden() }
                MacSheetSection(caption: "Reading") {
                    orderingPicker
                    openModePicker
                    stylingPicker
                }
                MacSheetSection(caption: "Feed") { healthRows }
                errorLabel
                unsubscribeButton
            }
        }
        #else
        Form {
            Section("Title") { titleField }
            Section("Folder") { folderPicker }
            Section("Reading") {
                orderingPicker
                openModePicker
                stylingPicker
            }
            Section("Feed") { healthRows }
            errorLabel
            Section { unsubscribeButton }
        }
        #endif
    }

    private var titleField: some View {
        TextField("Title", text: $form.customTitle, prompt: Text(subscription.feed?.title ?? "Feed title"))
            .labelsHidden()
            .accessibilityIdentifier("feed.settings.title")
    }

    private var folderPicker: some View {
        FeedFolderPicker(title: "Folder", selection: $form.folderId, folders: folders)
    }

    private var orderingPicker: some View {
        Picker("Order", selection: $form.orderingMode) {
            Text("Newest first").tag(RssOrderingMode.newestFirst)
            Text("Oldest first").tag(RssOrderingMode.oldestFirst)
            Text("Newest day, oldest first within").tag(RssOrderingMode.newestDayOldestWithin)
            Text("Oldest day, newest first within").tag(RssOrderingMode.oldestDayNewestWithin)
        }
    }

    private var openModePicker: some View {
        Picker("Open", selection: $form.defaultOpenMode) {
            Text("Feed content").tag(RssOpenMode.summary)
            Text("Article").tag(RssOpenMode.article)
        }
    }

    private var stylingPicker: some View {
        Picker("Styling", selection: $form.defaultStyling) {
            Text("Reader").tag(RssStyling.reader)
            Text("Original").tag(RssStyling.native)
        }
    }

    @ViewBuilder
    private var healthRows: some View {
        if let feed = subscription.feed {
            LabeledContent("Address", value: feed.canonicalUrl)
            if let site = URL(string: feed.siteUrl), !feed.siteUrl.isEmpty {
                LabeledContent("Site") {
                    Link(feed.siteUrl, destination: site)
                        .lineLimit(1)
                }
            }
            LabeledContent("Status", value: FeedHealthText.status(feed))
            if !feed.lastError.isEmpty, feed.consecutiveFailureCount > 0 {
                Text(feed.lastError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Last fetched", value: FeedHealthText.lastFetched(feed))
            LabeledContent("Checks", value: FeedHealthText.cadence(feed))
        } else {
            Text("Feed details arrive with the next refresh.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(ColorTokens.dangerFg)
        }
    }

    private var unsubscribeButton: some View {
        Button(role: .destructive) {
            confirmUnsubscribe = true
        } label: {
            Label("Unsubscribe", systemImage: "minus.circle")
        }
        .disabled(management.isBusy)
        .accessibilityIdentifier("feed.settings.unsubscribe")
    }

    private func save() async {
        guard let update = form.update(against: subscription) else { dismiss(); return }
        errorMessage = nil
        do {
            let updated = try await management.update(subscription, update)
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
    }

    private func unsubscribe() async {
        errorMessage = nil
        do {
            try await management.unsubscribe(subscription)
            onUnsubscribed(subscription)
            dismiss()
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
    }
}

/// Wording for a feed's fetcher health (`RssFeedSummary`), pure for tests.
enum FeedHealthText {
    static func status(_ feed: RssFeedSummary) -> String {
        if feed.deadLettered { return "Stopped: the fetcher gave up on this feed" }
        if feed.consecutiveFailureCount > 0 {
            return "Failing (\(feed.consecutiveFailureCount) in a row, last status \(feed.lastStatusCode))"
        }
        return feed.lastFetchedAt.isEmpty ? "Not fetched yet" : "OK"
    }

    static func lastFetched(_ feed: RssFeedSummary) -> String {
        guard !feed.lastFetchedAt.isEmpty else { return "Never" }
        let relative = FeedItemDate.relative(feed.lastFetchedAt)
        return relative.isEmpty ? feed.lastFetchedAt : relative
    }

    static func cadence(_ feed: RssFeedSummary) -> String {
        guard feed.cadenceMinutes > 0 else { return "Not scheduled yet" }
        if feed.cadenceMinutes < 60 { return "About every \(feed.cadenceMinutes) minutes" }
        let hours = feed.cadenceMinutes / 60
        return hours == 1 ? "About every hour" : "About every \(hours) hours"
    }
}
