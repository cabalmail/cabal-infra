import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copies `string` to the system pasteboard. iOS / visionOS go through
/// `UIPasteboard`; macOS through `NSPasteboard`. Centralized here so the
/// address copy actions and the "view source" sheet share one implementation
/// of the platform split rather than repeating the `#if canImport` dance.
@MainActor
func copyToPasteboard(_ string: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = string
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
}
