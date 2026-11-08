import Observation
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

    /// `UserDefaults` key for the interface-text size: the app's own text
    /// everywhere else (`appFont(_:)`). Load-bearing; don't rename without a
    /// migration.
    public static let interfaceDefaultsKey = "cabalmail.display.interface_text_size"

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

/// The stored text sizes, shared by the scene roots, the Settings row and
/// the View menu's commands.
///
/// An observable store rather than `@AppStorage` in each of them: an
/// `@AppStorage` property in a `Commands` body sent SwiftUI into an endless
/// update loop when the app hosted the test bundle (the runner then "hung
/// before establishing connection"). Here a view or command re-evaluates
/// only when a size it read actually changes, and `UserDefaults` is
/// written only then.
@Observable
@MainActor
public final class AppTextSizeStore {
    /// The app's store, over `UserDefaults.standard`.
    public static let shared = AppTextSizeStore()

    @ObservationIgnored private let defaults: UserDefaults

    /// The message-text size (`AppTextSize.contentDefaultsKey`).
    public var content: AppTextSize {
        didSet {
            guard content != oldValue else { return }
            defaults.set(content.rawValue, forKey: AppTextSize.contentDefaultsKey)
        }
    }

    /// The interface-text size (`AppTextSize.interfaceDefaultsKey`).
    public var interface: AppTextSize {
        didSet {
            guard interface != oldValue else { return }
            defaults.set(interface.rawValue, forKey: AppTextSize.interfaceDefaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        content = Self.read(AppTextSize.contentDefaultsKey, from: defaults)
        interface = Self.read(AppTextSize.interfaceDefaultsKey, from: defaults)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> AppTextSize {
        defaults.string(forKey: key).flatMap(AppTextSize.init(rawValue:)) ?? .medium
    }
}

extension EnvironmentValues {
    /// The message-text size the scene root read from the store
    /// (`appTextSize()`). `.medium` wherever no root sets it.
    @Entry var contentTextSize: AppTextSize = .medium

    /// The interface-text size the scene root read from the store
    /// (`appTextSize()`), which `appFont(_:)` draws at. `.medium` wherever
    /// no root sets it.
    @Entry var interfaceTextSize: AppTextSize = .medium

    /// The scale message content draws at: the system text size (Dynamic
    /// Type, where the platform has it) times the app's own message-text
    /// size. The HTML reader, the feed article reader and the composer
    /// multiply their text by it (`ReaderTextScale`).
    var contentTextScale: Double {
        dynamicTypeSize.bodyTextScale * contentTextSize.scale
    }
}

public extension View {
    /// Hands this scene the stored text sizes (`AppTextSizeStore`). A scene is
    /// its own environment root, so every scene root applies it, as it does
    /// `themedAppearance(_:)`.
    func appTextSize() -> some View {
        modifier(AppTextSizeRoot())
    }
}

private struct AppTextSizeRoot: ViewModifier {
    func body(content: Content) -> some View {
        let store = AppTextSizeStore.shared
        content
            // Text that names no font (form rows, labels, buttons) takes
            // the interface size from here. At `.medium` there is no
            // default, as before the setting.
            .font(store.interface == .medium ? nil : .app(.body, store.interface))
            .environment(\.interfaceTextSize, store.interface)
            .environment(\.contentTextSize, store.content)
    }
}
