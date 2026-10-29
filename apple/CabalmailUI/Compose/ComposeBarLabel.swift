import SwiftUI

/// What compose's Cancel and Send show in the bar.
///
/// A side strip (iPhone Duo's bars on its outer display, and in a wide window
/// inside) takes an item only if it has a symbol. An item with a title and no
/// symbol stays in a horizontal bar above the form, and on the trailing
/// compose sheet that bar scrolled away with the form, taking Cancel and Send
/// with it (#2259). So where the window's bars are vertical, both carry a
/// symbol. That puts them in the strip, which stays put, at the hardware edge
/// and clear of a book crease (#2262). Everywhere else they keep the titles
/// they have always had, so an iPhone, an iPad, the Mac and visionOS look as
/// before.
///
/// The choice reads the window's bars (`\.barsAreVertical`, published at the
/// root of a main window and of a compose window), not the sheet's own
/// `toolbarVerticalEdge`. On a reduction, a label that followed the sheet's
/// edge saw it go from trailing to nil, and Cancel and Send dropped out of
/// the bar.
enum ComposeBarLabel: Equatable {
    /// The symbol with its title, for a strip, which draws the symbol.
    case symbol
    /// The title alone.
    case title
    /// A spinner in Send's place while it sends.
    case progress

    static func cancel(barsAreVertical: Bool) -> Self {
        barsAreVertical ? .symbol : .title
    }

    /// Send keeps its symbol while sending where the bars are vertical,
    /// pulsing (`ComposeView`) rather than swapping to a spinner: the strip
    /// drops an item whose label is a spinner, and Send left the strip for as
    /// long as the send ran (measured on a reduction).
    static func send(barsAreVertical: Bool, isSending: Bool) -> Self {
        if barsAreVertical { return .symbol }
        return isSending ? .progress : .title
    }

    @ViewBuilder
    func label(_ title: LocalizedStringKey, systemImage: String) -> some View {
        switch self {
        case .symbol: Label(title, systemImage: systemImage)
        case .title: Text(title)
        case .progress: ProgressView()
        }
    }
}
