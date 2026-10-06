import SwiftUI
import CabalmailKit

/// Slot-addressed, total accessors for the one palette entry a
/// `FlagPaletteEntryEditor` is editing (#1340).
///
/// The editor is pushed on a `slot`, but every `Binding` it hands to a
/// live `TextField` or `Toggle` outlives the entry: confirming the delete
/// shrinks `Preferences.flagPalette` while those children are still
/// mounted, and SwiftUI pulls their getters during the very same update
/// pass — on macOS the hosting view's minimum-size recompute as the
/// Settings window resizes around the popped view, on iPadOS whatever
/// drives the popover's. A binding that captured the entry's *index* traps
/// there the moment the index is past the shrunken end, which is every
/// deletion of the last entry. Looking the slot up on each access is total
/// by construction: the entry is either found, or the accessor reads a
/// neutral value and writes nothing.
///
/// The same hazard covers the case the editor's `else` branch already
/// names — deleted on another device while the editor is open — which no
/// amount of guarding in `body` can reach, because the crash is in the
/// children's bindings and not in the body's own re-evaluation.
@MainActor
struct FlagPaletteEntryBindings {
    let preferences: Preferences
    let slot: String

    /// The entry being edited, or nil once it is gone.
    var entry: FlagPaletteEntry? {
        preferences.flagPalette.first { $0.slot == slot }
    }

    /// Label writes are capped to the server's length limit as they are
    /// typed. A momentarily empty label (mid-edit) stays local: the server
    /// rejects it, the push silently retries on the next keystroke, and
    /// nothing is lost — the same transient-invalid posture the reply-body
    /// editor takes.
    var label: Binding<String> {
        Binding(
            get: { self.entry?.label ?? "" },
            set: { newValue in
                self.write { $0.label = String(newValue.prefix(FlagPalette.maxLabelLength)) }
            }
        )
    }

    /// A write-through binding on one field, reading `fallback` when the
    /// entry is gone.
    func value<Value>(
        _ keyPath: WritableKeyPath<FlagPaletteEntry, Value>, or fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.entry?[keyPath: keyPath] ?? fallback },
            set: { newValue in self.set(keyPath, to: newValue) }
        )
    }

    /// A one-shot write on one field, for a control that acts rather than
    /// binds (the color grid). Same totality: gone means nothing happens.
    func set<Value>(_ keyPath: WritableKeyPath<FlagPaletteEntry, Value>, to newValue: Value) {
        write { $0[keyPath: keyPath] = newValue }
    }

    /// Removes the entry. `Preferences` keeps syncing an emptied palette,
    /// so the deletion reaches the server like any other edit.
    func delete() {
        preferences.flagPalette.removeAll { $0.slot == slot }
    }

    /// Mutates the entry in place, or does nothing when it is gone. The
    /// index is looked up and spent inside one call, never captured.
    private func write(_ mutate: (inout FlagPaletteEntry) -> Void) {
        var palette = preferences.flagPalette
        guard let index = palette.firstIndex(where: { $0.slot == slot }) else { return }
        mutate(&palette[index])
        preferences.flagPalette = palette
    }
}
