import SwiftUI

/// The flags an open message or feed item carries, named: a color dot and
/// the flag's label per mark, in palette order, under each reader's header.
/// A row has room for dots only (`FlagDots`); the reader names them.
///
/// A flow rather than an `HStack`: an item can carry every flag in the
/// palette, and `maxWidth` caps how wide the chips may run before wrapping.
/// A deleted flag's surviving tag shows its slot id in gray, per the
/// palette editor's delete-confirmation copy.
struct FlagChips: View {
    let marks: [FlagDotMark]
    var maxWidth: CGFloat = .infinity

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4, maxLineWidth: maxWidth) {
            ForEach(marks) { mark in
                HStack(spacing: 4) {
                    Circle()
                        .fill(FlagPaletteColor.color(for: mark.color))
                        .frame(width: 8, height: 8)
                    Text(mark.label)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}
