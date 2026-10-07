import SwiftUI
import CabalmailKit

/// One filter pill: its label, an optional count, and the accent wash while
/// it is the filter in force. Every pill row draws its pills with this, so
/// the message list, the feed item list and both sidebar filter rows look
/// alike. What a tap means (a radio choice or a toggle) is the caller's; the
/// pill only draws what it is told is on.
struct FilterPill: View {
    let label: String
    let isOn: Bool
    /// The number after the label. Nil draws none.
    var count: Int?
    /// Machine-facing name, kept on the pill's button.
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(isOn ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(FilterPillCountStyle.countEmphasis().shapeStyle)
                }
            }
            // Keep the label on one line; `FilterPillStrip` relies on this
            // to tell that a row no longer fits and stack the pills instead.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isOn ? ColorTokens.accentForestWash : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenLabel(label, count: count))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// What VoiceOver reads: the label, then the count when there is one.
    static func spokenLabel(_ label: String, count: Int?) -> String {
        guard let count else { return label }
        return "\(label), \(count)"
    }
}

/// Filter pills in a row that stacks them when the row is too narrow.
/// Without the fallback the labels wrap a character at a time once the bar
/// is squeezed, which is unreadable. Beside a `Spacer` and trailing controls
/// in an `HStack`, the pills stack only when the whole row cannot fit.
struct FilterPillStrip<Pills: View>: View {
    @ViewBuilder let pills: () -> Pills

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { pills() }
            VStack(alignment: .leading, spacing: 4) { pills() }
        }
    }
}
