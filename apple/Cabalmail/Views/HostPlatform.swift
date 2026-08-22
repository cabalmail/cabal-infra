/// The platform a view is being drawn on, as far as the view-level policies
/// care. Only the distinctions that change a rule are modelled.
///
/// Its own file because more than one policy asks the question, and because
/// the targets that compile those policies are not the same set — the watch
/// app takes `ConfirmationDialogPolicy` and nothing else (#1207).
enum HostPlatform {
    case macOS
    case iOS
    case visionOS
    case watchOS

    /// The platform this build is compiled for.
    static var current: HostPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(watchOS)
        return .watchOS
        #else
        return .iOS
        #endif
    }
}
