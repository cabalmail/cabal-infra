import CabalmailKit
import SwiftUI

/// Large-type display of one address — the "show your wrist" view.
///
/// Tapping a list row lands here so the address can be read out (or shown
/// to someone) without squinting at a two-line row. watchOS has no
/// pasteboard, so large and legible IS the hand-off — same rationale as
/// the new-address success screen.
struct AddressDetailView: View {
    let address: Address

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let comment = address.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(address.address)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                if address.favorite {
                    Label("Favorite", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
