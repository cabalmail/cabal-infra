import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's own text in a text style, at the interface text size
/// (`AppTextSize`, Settings > Appearance > Interface text on the Mac).
///
/// SwiftUI's text styles are fixed point sizes on macOS: `dynamicTypeSize`
/// changes nothing there, so the Mac's text size has to be applied at each
/// call site. `appFont(_:)` is that call site. At `.medium` it is exactly
/// the text style, so the default look, and Dynamic Type everywhere it
/// exists, are untouched; at another step it is the platform's own size for
/// the style times the step's scale, in the style's own weight, so the
/// styles keep their sizes relative to each other.
///
/// The `raw_text_style_font` SwiftLint rule keeps `.font(.caption)` and the
/// like out of `CabalmailUI` and `CabalmailMac`: a raw text style would
/// silently ignore the setting.
public extension View {
    func appFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        monospaced: Bool = false,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(AppFontModifier(
            style: style, weight: weight, monospaced: monospaced, monospacedDigit: monospacedDigit
        ))
    }
}

private struct AppFontModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let monospaced: Bool
    let monospacedDigit: Bool
    @Environment(\.interfaceTextSize) private var size

    func body(content: Content) -> some View {
        content.font(.app(
            style, size, weight: weight, monospaced: monospaced, monospacedDigit: monospacedDigit
        ))
    }
}

extension Font {
    /// The font `appFont(_:)` applies; see there.
    static func app(
        _ style: TextStyle,
        _ size: AppTextSize,
        weight: Weight? = nil,
        monospaced: Bool = false,
        monospacedDigit: Bool = false
    ) -> Font {
        var font: Font
        if size == .medium {
            font = .system(style)
        } else {
            let platformFont = Self.platformFont(for: style)
            font = Font(platformFont.withSize(Self.scaledPointSize(platformFont.pointSize, size)) as CTFont)
        }
        if let weight { font = font.weight(weight) }
        if monospaced { font = font.monospaced() }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }

    /// Smallest size a step down may draw: text already smaller than this
    /// keeps its size, and nothing shrinks below it.
    static let minimumScaledPointSize: CGFloat = 9

    /// `base` times the step's scale, but no smaller than
    /// `minimumScaledPointSize` (or `base`, if that is smaller still).
    static func scaledPointSize(_ base: CGFloat, _ size: AppTextSize) -> CGFloat {
        max(base * size.scale, min(base, minimumScaledPointSize))
    }

    /// The point size the platform draws a text style at, at the default
    /// size.
    static func platformPointSize(for style: TextStyle) -> CGFloat {
        platformFont(for: style).pointSize
    }

    #if canImport(UIKit)
    private typealias PlatformFont = UIFont
    #else
    private typealias PlatformFont = NSFont
    #endif

    private static func platformFont(for style: TextStyle) -> PlatformFont {
        PlatformFont.preferredFont(forTextStyle: platformStyles[style] ?? .body)
    }

    /// SwiftUI's text styles by their UIKit / AppKit names, which are the
    /// same on both. A style missing here (visionOS's extra-large title)
    /// takes the body size.
    private static let platformStyles: [TextStyle: PlatformFont.TextStyle] = [
        .largeTitle: .largeTitle,
        .title: .title1,
        .title2: .title2,
        .title3: .title3,
        .headline: .headline,
        .subheadline: .subheadline,
        .body: .body,
        .callout: .callout,
        .footnote: .footnote,
        .caption: .caption1,
        .caption2: .caption2,
    ]
}
