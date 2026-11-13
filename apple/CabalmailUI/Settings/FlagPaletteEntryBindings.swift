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
/// The editor is pushed on a `slot`, but the `Binding` it hands to a
/// live `TextField` outlives the entry: confirming the delete
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

    /// Whether this entry is the default flag, the one the swipe, the flag
    /// button and the flag shortcuts set: the first entry.
    var isDefault: Bool {
        FlagPalette.defaultEntry(in: preferences.flagPalette).slot == slot
    }

    /// Whether `makeDefault()` would change anything: the entry is there
    /// and is not the default already.
    var canMakeDefault: Bool {
        entry != nil && !isDefault
    }

    /// The palette as the list shows it.
    private var palette: [FlagPaletteEntry] {
        FlagPalette.effective(preferences.flagPalette)
    }

    /// Whether `text` is a name the palette stores: one the server's rules
    /// (`ServerTextRules.flagLabel(_:)`) leave something of. Empty text is
    /// not, and neither is text they reduce to nothing: control characters
    /// alone, or a single character of more code points than a name may
    /// have.
    nonisolated static func isName(_ text: String) -> Bool {
        !ServerTextRules.flagLabel(text).isEmpty
    }

    /// The name, written as it is typed; `Preferences` holds it to what
    /// the server takes (`ServerTextRules.flagLabel(_:)`), so a long name
    /// is cut at 32 code points. Text that is not a name (`isName(_:)`) is
    /// not written: the server refuses the whole settings map over an
    /// empty name (#2439), so until the field holds a name again the flag
    /// keeps the last one it had, and the editor's `FlagNameField` settles
    /// it on leaving.
    var label: Binding<String> {
        Binding(
            get: { self.entry?.label ?? "" },
            set: { newValue in
                guard Self.isName(newValue) else { return }
                self.write { $0.label = newValue }
            }
        )
    }

    /// On leaving the editor: a name field left empty gives the flag back
    /// the name it had when the editor opened, not the last letters it held
    /// on the way to empty. `FlagNameField.leave()` decides both arguments.
    func leaveEditor(nameFieldEmpty: Bool, openedWith opening: String) {
        guard nameFieldEmpty else { return }
        label.wrappedValue = opening
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

    /// Makes the entry the default flag by moving it to the top of the
    /// palette: the default is a position, not a field, so every shipped
    /// build and the other platforms read it the same way. Nothing is
    /// written when `canMakeDefault` is false.
    func makeDefault() {
        guard canMakeDefault else { return }
        var palette = self.palette
        guard let index = palette.firstIndex(where: { $0.slot == slot }) else { return }
        palette.insert(palette.remove(at: index), at: 0)
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
