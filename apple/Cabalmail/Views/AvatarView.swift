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
/// 3. A circle with the sender's initials. Rendered as the base layer
///    while a photo or BIMI logo is still loading (and as the fallback
///    when neither resolves), so the avatar slot is never empty. It is
///    *not* drawn behind a successfully-loaded BIMI logo: those assets
///    carry transparent margins, and a colored fill would show through
///    as a background halo (e.g. UPS's shield on a red disc). Letting the
///    transparency pass through blends the logo with the surrounding list
///    in both light and dark mode.
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
            if let contactPhotoData {
                // Photos fill the slot; keep the colored base beneath so any
                // scaled-to-fit margins read as a deliberate swatch, matching
                // prior behavior.
                initialsCircle
                contactPhotoView(data: contactPhotoData)
            } else if let bimiURL {
                AsyncImage(url: bimiURL) { phase in
                    switch phase {
                    case .success(let image):
                        // No colored base behind a resolved BIMI logo — let its
                        // transparent margins blend with the surrounding list.
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure, .empty:
                        initialsCircle
                    @unknown default:
                        initialsCircle
                    }
                }
                .frame(width: size, height: size)
            } else {
                initialsCircle
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
                    .foregroundStyle(initialsForeground)
            )
            .frame(width: size, height: size)
    }

    /// Stable color per sender *domain* so every message from the same
    /// domain shows the same swatch — a whole correspondent's domain reads
    /// as one color, which is easier to scan than a per-address rainbow.
    /// Keyed on the host alone (lowercased), disregarding the local part.
    ///
    /// Uses a fixed FNV-1a hash over the UTF-8 bytes rather than
    /// `String.hashValue`, which is seeded with a per-process random value
    /// and so would pick a different color on every app launch.
    private var backgroundColor: Color {
        let key = (sender?.host ?? "").lowercased()
        // Muted pastels and earth tones — low saturation keeps a wall of
        // avatars calm. Initials render in `initialsForeground`, a dark
        // ink chosen to stay legible on every swatch below.
        let palette: [Color] = [
            Color(red: 0.86, green: 0.72, blue: 0.70), // dusty rose
            Color(red: 0.73, green: 0.81, blue: 0.69), // sage
            Color(red: 0.89, green: 0.83, blue: 0.66), // sand
            Color(red: 0.71, green: 0.80, blue: 0.85), // dusty sky
            Color(red: 0.85, green: 0.70, blue: 0.58), // terracotta
            Color(red: 0.79, green: 0.74, blue: 0.85), // lavender
            Color(red: 0.67, green: 0.80, blue: 0.78), // muted teal
            Color(red: 0.90, green: 0.78, blue: 0.66), // pale peach
            Color(red: 0.75, green: 0.76, blue: 0.61), // moss
            Color(red: 0.80, green: 0.76, blue: 0.71)  // taupe
        ]
        // FNV-1a (64-bit): deterministic across launches and platforms.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }

    /// Dark, warm-neutral ink for the initials. Legible on every pastel /
    /// earth-tone swatch in `backgroundColor`, where white would wash out.
    private var initialsForeground: Color {
        Color(red: 0.20, green: 0.19, blue: 0.17)
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
    ///
    /// In the virtualized message list, row views are recycled by index as
    /// the loaded window scrolls and as new mail arrives at the top. A row
    /// can be reassigned to a different sender while a prior sender's async
    /// lookup is still outstanding. SwiftUI cancels the superseded `.task`
    /// when `senderKey` changes, but cooperative cancellation doesn't stop
    /// the awaited cache/contacts calls from returning a value — so without
    /// an explicit recheck the stale result would land in this row's
    /// `@State` and paint the wrong sender's logo. After each await, bail if
    /// the task was cancelled (i.e. the row has moved on to another sender).
    private func loadIfNeeded() async {
        contactPhotoData = nil
        bimiURL = nil
        guard let sender else { return }
        if let photo = await appState.contactsStore.photoData(for: sender) {
            guard !Task.isCancelled else { return }
            contactPhotoData = photo
            return
        }
        guard !Task.isCancelled, !sender.host.isEmpty else { return }
        // Resolve through the shared session cache so the same domain isn't
        // re-fetched as list rows recycle (the detail view benefits too).
        let url = await appState.bimiCache.url(forDomain: sender.host) { domain in
            try? await apiClient.fetchBimiURL(senderDomain: domain)
        }
        guard !Task.isCancelled else { return }
        bimiURL = url
    }
}
