import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension DynamicTypeSize {
    /// How much larger than the default this size draws body text: the body
    /// text style's point size at this size over its size at `.large`. The
    /// web readers multiply their text by it (`ReaderTextScale`), so an HTML
    /// body follows the system text size the way `PlainTextBodyView`'s
    /// `.body` font already does. Read from UIKit rather than a copy of the
    /// type ramp, so it is the size `.body` actually draws at, on every
    /// platform that has one: at `.accessibility3` that is 40pt, not the
    /// 37pt `UIFontMetrics` gives for a custom 17pt font.
    ///
    /// macOS has no Dynamic Type: the reader keeps its own 17px there.
    var bodyTextScale: Double {
        #if canImport(UIKit)
        let size = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(self))
        ).pointSize
        let base = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        return base > 0 ? Double(size / base) : 1
        #else
        return 1
        #endif
    }
}
