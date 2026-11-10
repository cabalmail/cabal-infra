import SwiftUI
import CabalmailKit

/// Slot-addressed, total accessors for one palette entry: the one a
/// `FlagPaletteEntryEditor` is editing (#1340), or the one a row's Move Up /
/// Move Down items move.
///
/// They read and edit the *effective* palette, the list Settings > Flags
/// shows: the stored palette with the system flag's entry supplied when it
/// has none. Every write goes back through
/// `FlagPalette.stored(afterEditing:from:)`, so the system entry reaches
/// `Preferences.flagPalette`, and the wire, only once the user has changed
/// it or moved something above it.
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

    /// The entry being edited, or nil once it is gone. The system flag's
    /// entry is never gone.
    var entry: FlagPaletteEntry? {
        palette.first { $0.slot == slot }
    }

    /// Whether this is the system flag's entry, which resets where the
    /// others delete.
    var isSystemEntry: Bool { slot == FlagPalette.systemSlot }

    /// Whether `reset()` would change anything: the system entry is stored,
    /// so it is not, or not only, the default one in first place.
    var canReset: Bool {
        isSystemEntry && preferences.flagPalette.contains { $0.slot == slot }
    }

    /// The palette as the list shows it.
    private var palette: [FlagPaletteEntry] {
        FlagPalette.effective(preferences.flagPalette)
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
    /// so the deletion reaches the server like any other edit. The system
    /// flag cannot be deleted, so for its entry this is `reset()`.
    func delete() {
        guard !isSystemEntry else { return reset() }
        preferences.flagPalette.removeAll { $0.slot == slot }
    }

    /// Puts the system flag's entry back to its default name, color and
    /// first place, by dropping the stored entry. Nothing is written when
    /// there is none to drop, or for any other entry.
    func reset() {
        guard canReset else { return }
        preferences.flagPalette = FlagPalette.resettingSystemEntry(in: preferences.flagPalette)
    }

    /// Whether `move(by:)` would move the entry: false past either end of
    /// the palette, and once the entry is gone.
    func canMove(by offset: Int) -> Bool {
        let palette = self.palette
        guard offset != 0,
              let index = palette.firstIndex(where: { $0.slot == slot })
        else { return false }
        return palette.indices.contains(index + offset)
    }

    /// Moves the entry `offset` places through the palette (-1 is Move Up,
    /// +1 Move Down), which is the order pickers use. Past either end, or
    /// once the entry is gone, nothing is written, so nothing is pushed.
    func move(by offset: Int) {
        guard canMove(by: offset) else { return }
        var palette = self.palette
        guard let index = palette.firstIndex(where: { $0.slot == slot }) else { return }
        palette.insert(palette.remove(at: index), at: index + offset)
        store(palette)
    }

    /// Mutates the entry in place, or does nothing when it is gone. The
    /// index is looked up and spent inside one call, never captured.
    private func write(_ mutate: (inout FlagPaletteEntry) -> Void) {
        var palette = self.palette
        guard let index = palette.firstIndex(where: { $0.slot == slot }) else { return }
        mutate(&palette[index])
        store(palette)
    }

    private func store(_ edited: [FlagPaletteEntry]) {
        preferences.flagPalette = FlagPalette.stored(afterEditing: edited, from: preferences.flagPalette)
    }
}
