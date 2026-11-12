import SwiftUI
import CabalmailKit

/// One filter pill: its label, an optional count, and the accent wash while
/// it is the filter in force (`FilterPillFace`). Every pill row draws its
/// pills with this, so the message list, the feed item list and both sidebar
/// filter rows look alike. What a tap means (a radio choice or a toggle) is
/// the caller's; the pill only draws what it is told is on. A list bar's
/// Flagged pill is this one until Settings > Flags holds a flag of the
/// user's own, and `FlagFilterPill`, a menu with the same face, after.
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
            FilterPillFace(label: label, isOn: isOn, count: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenLabel(label, count: count))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// What VoiceOver reads: the label, then the count when there is one,
    /// grouped for the locale the way the drawn count is ("All, 12,345").
    static func spokenLabel(_ label: String, count: Int?) -> String {
        guard let count else { return label }
        return "\(label), \(count.formatted())"
    }
}

/// What a filter pill draws: its label, an optional count, and the accent
/// wash while it is lit. `FilterPill` puts it in a button; the Flagged
/// pill of a list bar puts it in a menu (`FlagFilterPill`), and the two
/// must look alike.
struct FilterPillFace: View {
    let label: String
    let isOn: Bool
    /// The number after the label. Nil draws none.
    var count: Int?
    /// A number to keep room for while `count` is nil: drawn unseen, so the
    /// face is as wide as it will be once the count arrives.
    var reservedCount: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .appFont(.subheadline, weight: isOn ? .semibold : .regular)
            if let shown = count ?? reservedCount {
                Text("\(shown)")
                    .appFont(.caption)
                    .foregroundStyle(FilterPillCountStyle.countEmphasis().shapeStyle)
                    .opacity(count == nil ? 0 : 1)
                    .accessibilityHidden(count == nil)
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
