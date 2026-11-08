import SwiftUI

/// One step of the app's own text-size ramp, for the platform that has no
/// system-wide one: macOS has no Dynamic Type, so the Mac offers this in
/// Settings > Appearance instead (`HostPlatform.offersAppTextSize`).
///
/// A step is a ratio, not a point size: `.medium` is the size each surface
/// drew at before the setting existed, and the others scale from there.
///
/// Stored device-wide in `UserDefaults`, not in the account-scoped,
/// server-synced `Preferences`: a comfortable size depends on the display
/// and the eyes in front of it, not on the Cabalmail account.
public enum AppTextSize: String, CaseIterable, Identifiable, Sendable {
    case xSmall = "x_small"
    case small
    case medium
    case large
    case xLarge = "x_large"

    /// `UserDefaults` key for the message-text size: message bodies, feed
    /// articles and the composer. Load-bearing; don't rename without a
    /// migration.
    public static let contentDefaultsKey = "cabalmail.display.content_text_size"

    public var id: String { rawValue }

    /// How much larger than `.medium` this step draws text.
    public var scale: Double {
        switch self {
        case .xSmall: 0.85
        case .small: 0.93
        case .medium: 1
        case .large: 1.15
        case .xLarge: 1.3
        }
    }

    public var title: String {
        switch self {
        case .xSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium (Default)"
        case .large: "Large"
        case .xLarge: "Extra Large"
        }
    }

    /// The next step up, or nil at the top of the ramp.
    public var larger: AppTextSize? {
        Self.allCases.firstIndex(of: self).flatMap { index in
            Self.allCases.indices.contains(index + 1) ? Self.allCases[index + 1] : nil
        }
    }

    /// The next step down, or nil at the bottom of the ramp.
    public var smaller: AppTextSize? {
        Self.allCases.firstIndex(of: self).flatMap { index in
            index > 0 ? Self.allCases[index - 1] : nil
        }
    }
}

extension EnvironmentValues {
    /// The message-text size the scene root read from `UserDefaults`
    /// (`appTextSize()`). `.medium` wherever no root sets it.
    @Entry var contentTextSize: AppTextSize = .medium

    /// The scale message content draws at: the system text size (Dynamic
    /// Type, where the platform has it) times the app's own message-text
    /// size. The HTML reader, the feed article reader and the composer
    /// multiply their text by it (`ReaderTextScale`).
    var contentTextScale: Double {
        dynamicTypeSize.bodyTextScale * contentTextSize.scale
    }
}

public extension View {
    /// Hands this scene the text sizes stored in `UserDefaults`. A scene is
    /// its own environment root, so every scene root applies it, as it does
    /// `themedAppearance(_:)`.
    func appTextSize() -> some View {
        modifier(AppTextSizeRoot())
    }
}

private struct AppTextSizeRoot: ViewModifier {
    @AppStorage(AppTextSize.contentDefaultsKey) private var contentSize: AppTextSize = .medium

    func body(content: Content) -> some View {
        content.environment(\.contentTextSize, contentSize)
    }
}
