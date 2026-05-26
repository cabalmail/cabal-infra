import SwiftUI
import CabalmailKit

/// Sender avatar shown next to the From line in `MessageDetailView`. Tries
/// the BIMI logo first (the Lambda's `/fetch_bimi` endpoint resolves the
/// sender domain's BIMI record and returns a presigned S3 URL for the
/// signed SVG / image asset); falls back to a circle with the sender's
/// initials when no BIMI is published or the lookup fails.
///
/// BIMI is sender-published, fetched via our own Lambda (not the sender's
/// domain directly), so there's no tracking-pixel risk: loading the
/// avatar can't leak read state to the sender. The remote-content
/// preference exists for HTML body resources; this surface is safe to
/// load unconditionally.
struct AvatarView: View {
    let sender: EmailAddress?
    let apiClient: ApiClient
    var size: CGFloat = 40

    @State private var bimiURL: URL?
    @State private var bimiAttempted = false

    var body: some View {
        ZStack {
            initialsCircle
            if let bimiURL {
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
        .task(id: domainKey) { await loadBimiIfNeeded() }
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

    /// Stable identifier used as `.task(id:)` so the BIMI fetch re-fires
    /// when the user opens a different message from a different domain.
    private var domainKey: String { sender?.host ?? "" }

    private func loadBimiIfNeeded() async {
        guard !bimiAttempted else { return }
        bimiAttempted = true
        guard let host = sender?.host, !host.isEmpty else { return }
        bimiURL = try? await apiClient.fetchBimiURL(senderDomain: host)
    }
}
