#if os(macOS)
import SwiftUI

/// Shared chrome for the app's small form sheets on macOS — the "create X"
/// sheets and the search Filters sheet.
///
/// macOS `Form` promotes every control's title into an external leading
/// label column and gives its rows no horizontal content margins, so a
/// `Form` inside a sheet draws that column hard against the sheet's left
/// border and stretches its fields flush to the right one (#1063, #1484,
/// #1501). These sheets therefore hand-build their macOS layout instead:
/// headline captions in place of section headers, in-field placeholders,
/// and real content margins. The numbers live here rather than in each
/// sheet so the two cannot drift apart.
struct MacSheetForm<Content: View>: View {
    /// Inset from every edge of the sheet.
    static var contentPadding: CGFloat { 24 }
    /// Width of the sheet, insets included. A sheet sizes itself to its
    /// content, so this is what fixes the sheet's own width.
    static var contentWidth: CGFloat { 460 }
    /// Gap between one captioned group and the next.
    static var sectionSpacing: CGFloat { 20 }

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            content
        }
        .padding(Self.contentPadding)
        .frame(width: Self.contentWidth, alignment: .leading)
    }
}

/// One captioned group inside a `MacSheetForm` — the macOS stand-in for a
/// `Form`'s `Section(_:)` header, which is what the hand-built layout gives
/// up.
struct MacSheetSection<Content: View>: View {
    /// Gap between the caption and the controls it introduces.
    static var captionSpacing: CGFloat { 8 }

    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Self.captionSpacing) {
            Text(caption)
                .font(.headline)
            content
        }
    }
}
#endif
