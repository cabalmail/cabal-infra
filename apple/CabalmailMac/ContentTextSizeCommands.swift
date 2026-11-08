import SwiftUI
import CabalmailUI

/// View > Larger / Smaller / Default Message Text Size: message bodies,
/// feed articles and the composer, the size Settings > Appearance > Message
/// text also sets (`AppTextSize`). ⌘+, ⌘− and ⌘0, the chords Mail and
/// Safari use for their content; the rest of the app's text has no chords.
///
/// Menu-bar commands rather than view shortcuts, so they work whichever
/// window or pane has focus. They write the shared store, which every
/// scene root reads (`appTextSize()`), so every open reader and composer
/// follows at once. The store is passed in rather than read through
/// `@AppStorage` here; see `AppTextSizeStore` for why.
struct ContentTextSizeCommands: Commands {
    let store: AppTextSizeStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Larger Message Text") {
                if let larger = store.content.larger { store.content = larger }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(store.content.larger == nil)
            Button("Smaller Message Text") {
                if let smaller = store.content.smaller { store.content = smaller }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(store.content.smaller == nil)
            Button("Default Message Text Size") {
                store.content = .medium
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(store.content == .medium)
        }
    }
}
