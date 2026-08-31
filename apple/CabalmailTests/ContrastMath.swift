import Foundation

/// WCAG relative luminance and contrast over 8-bit sRGB, plus source-over
/// compositing so an opacity can be turned into the pixel it produces.
///
/// Test-only: the app never computes a contrast ratio, it just has to clear
/// one. Shared by `FolderNameTintTests` (#1297) and `FolderIconTintTests`
/// (#1318), which reason about the same measured sidebar pixels.
struct RGB {
    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)

    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// This colour with `other` laid over it at `alpha`, which is what a
    /// `Color.primary.opacity(_:)` label does to the pixel beneath it.
    func composited(with other: RGB, alpha: Double) -> RGB {
        RGB(
            red + (other.red - red) * alpha,
            green + (other.green - green) * alpha,
            blue + (other.blue - blue) * alpha
        )
    }

    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            let unit = value / 255
            return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: RGB) -> Double {
        let lhs = relativeLuminance
        let rhs = other.relativeLuminance
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}
