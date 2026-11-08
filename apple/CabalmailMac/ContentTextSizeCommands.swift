import SwiftUI
import CabalmailUI

/// View > Larger / Smaller / Default Message Text Size: message bodies,
/// feed articles and the composer, the size Settings > Appearance > Message
/// text also sets (`AppTextSize`). ⌘+, ⌘− and ⌘0, the chords Mail and
/// Safari use for their content; the rest of the app's text has no chords.
///
/// Menu-bar commands rather than view shortcuts, so they work whichever
/// window or pane has focus. They write the stored size, which every
/// scene root reads (`appTextSize()`), so every open reader and composer
/// follows at once.
struct ContentTextSizeCommands: Commands {
    @AppStorage(AppTextSize.contentDefaultsKey) private var size: AppTextSize = .medium

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Larger Message Text") {
                if let larger = size.larger { size = larger }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(size.larger == nil)
            Button("Smaller Message Text") {
                if let smaller = size.smaller { size = smaller }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(size.smaller == nil)
            Button("Default Message Text Size") {
                size = .medium
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(size == .medium)
        }
    }
}
