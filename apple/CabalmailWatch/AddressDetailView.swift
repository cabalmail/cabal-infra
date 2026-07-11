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
                    // largeTitle (~32pt on watchOS) over the original
                    // title3 (~19pt): device testing found title3 not big
                    // enough to comfortably show across a counter. Long
                    // addresses wrap to more lines and scroll — the right
                    // trade for a display meant to be read at arm's length.
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
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
