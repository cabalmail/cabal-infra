import SwiftUI
import CabalmailKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sender avatar shown next to the From line in `MessageDetailView`.
///
/// Source precedence:
/// 1. A photo from the user's own Apple Contacts entry for this sender,
///    if Contacts is authorized and a match exists. This is local-only
///    — no network round-trip — and reflects the user's own choice of
///    image for the contact, so it deserves top billing.
/// 2. The sender domain's BIMI logo. Resolved via the Lambda's
///    `/fetch_bimi` endpoint (which returns a presigned S3 URL for the
///    signed asset), so loading it can't leak read state to the sender's
///    domain directly.
/// 3. A circle with the sender's initials. Always rendered as the base
///    layer so the avatar slot is never empty during the async load.
///
/// Gravatar is deliberately *not* a source. Querying gravatar.com keyed
/// on the sender's email hash would opt the recipient into a third-party
/// lookup on the sender's say-so; we don't ship that.
struct AvatarView: View {
    let sender: EmailAddress?
    let apiClient: ApiClient
    var size: CGFloat = 40

    @Environment(AppState.self) private var appState
    @State private var contactPhotoData: Data?
    @State private var bimiURL: URL?

    var body: some View {
        ZStack {
            initialsCircle
            if let contactPhotoData {
                contactPhotoView(data: contactPhotoData)
            } else if let bimiURL {
                AsyncImage(url: bimiURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
        .task(id: senderKey) { await loadIfNeeded() }
    }

    @ViewBuilder
    private func contactPhotoView(data: Data) -> some View {
        #if os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
        #else
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
        #endif
    }

    @ViewBuilder
    private var initialsCircle: some View {
        Circle()
            .fill(backgroundColor)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }

    /// Stable color per sender so the same correspondent always shows
    /// the same swatch — easier to scan than randomly-rotating colors.
    /// Hash the full mailbox+host so two senders at the same domain
    /// don't collide visually.
    private var backgroundColor: Color {
        let key = "\(sender?.mailbox ?? "")@\(sender?.host ?? "")"
        let palette: [Color] = [
            .blue, .teal, .indigo, .purple, .pink,
            .orange, .brown, .green, .mint, .cyan
        ]
        let index = abs(key.hashValue) % palette.count
        return palette[index]
    }

    private var initials: String {
        guard let sender else { return "?" }
        if let name = sender.displayName, !name.isEmpty {
            return name
                .split(separator: " ")
                .prefix(2)
                .compactMap { $0.first.map(String.init) }
                .joined()
                .uppercased()
        }
        return sender.mailbox.first.map { String($0).uppercased() } ?? "?"
    }

    private var accessibilityLabel: String {
        if let name = sender?.displayName, !name.isEmpty { return name }
        if let sender { return "\(sender.mailbox)@\(sender.host)" }
        return "Unknown sender"
    }

    /// Stable identifier used as `.task(id:)` so the avatar load re-fires
    /// when the user opens a different message from a different sender.
    /// Hosts that change case across messages (rare but possible) still
    /// hit the same cache key downstream.
    private var senderKey: String {
        guard let sender else { return "" }
        return "\(sender.mailbox.lowercased())@\(sender.host.lowercased())"
    }

    /// Re-fired by SwiftUI whenever `senderKey` changes. Resets the
    /// per-sender state at entry so a row reused for a different sender
    /// can't paint the previous one's photo / BIMI while the new
    /// lookups are in flight.
    private func loadIfNeeded() async {
        contactPhotoData = nil
        bimiURL = nil
        guard let sender else { return }
        if let photo = await appState.contactsStore.photoData(for: sender) {
            contactPhotoData = photo
            return
        }
        guard !sender.host.isEmpty else { return }
        bimiURL = try? await apiClient.fetchBimiURL(senderDomain: sender.host)
    }
}
