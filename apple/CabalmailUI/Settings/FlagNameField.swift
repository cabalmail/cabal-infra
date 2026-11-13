import SwiftUI
import CabalmailKit

/// The name field of the flag editor (`FlagPaletteEntryEditor`): what the
/// field shows, what its typing stores, and what leaving the editor does
/// to the name.
///
/// The palette never holds an empty name (`FlagPaletteEntryBindings.label`),
/// so a field the user has emptied shows nothing while the flag still has
/// a name: the last one the field wrote on its way to empty. Leaving the
/// editor like that gives the flag back the name it opened with (#2439).
///
/// The flag can also get a name by a route that is not this field: Reset
/// to Default, or a pull that brings a rename made on another device. That
/// name is the newer one, so the field shows it, and it becomes the name
/// to give back; leaving never writes an older name over it (#2448). The
/// field tells the two apart by remembering the name its own last write
/// left: a name that differs from it came from elsewhere.
///
/// A value type the editor keeps in `@State` and the tests drive directly;
/// nothing here depends on the view.
@MainActor
struct FlagNameField {
    private let bindings: FlagPaletteEntryBindings
    /// Whether the user has emptied the field and typed no name since.
    private var emptied = false
    /// The name to give back when the editor is left with the field
    /// empty: the one the flag had when the editor opened, or the last one
    /// it got from elsewhere since.
    private var openingName: String?
    /// The flag's name as this field last knew it: at opening, after each
    /// write of its own, and after each name taken from elsewhere.
    private var knownName: String?

    init(preferences: Preferences, slot: String) {
        self.init(FlagPaletteEntryBindings(preferences: preferences, slot: slot))
    }

    /// A field that knows no name yet: it takes the flag's at first use.
    private init(_ bindings: FlagPaletteEntryBindings) {
        self.bindings = bindings
    }

    /// The field's text: the flag's name, or nothing while the user has
    /// emptied it. Text that is not a name (`FlagPaletteEntryBindings.isName(_:)`)
    /// empties the field and writes nothing.
    var text: String {
        get {
            let name = bindings.entry?.label
            return emptied && name == knownName ? "" : name ?? ""
        }
        set {
            followNameFromElsewhere()
            guard FlagPaletteEntryBindings.isName(newValue) else {
                emptied = true
                return
            }
            emptied = false
            bindings.label.wrappedValue = newValue
            // As stored, which is not always as typed: the rules may have
            // cut it.
            knownName = bindings.entry?.label
        }
    }

    /// Reset to Default, for the built-in flag's entry. The default name
    /// is the flag's name from here on, so the field shows it, emptied or
    /// not, and leaving gives back nothing older.
    mutating func resetToDefault() {
        guard bindings.canReset else { return }
        bindings.reset()
        take(bindings.entry?.label)
    }

    /// On leaving the editor: a field left empty gives the flag back the
    /// name it opened with, unless the flag has had a name from elsewhere
    /// since, which stays. A later visit to the same editor opens anew.
    mutating func leave() {
        followNameFromElsewhere()
        if emptied, let openingName {
            bindings.leaveEditor(nameFieldEmpty: true, openedWith: openingName)
        }
        self = FlagNameField(bindings)
    }

    /// Takes the flag's name when it is not the one this field last knew,
    /// which means it came by another route: a pull, or the name the
    /// editor opened on, since the field starts out knowing none.
    private mutating func followNameFromElsewhere() {
        let name = bindings.entry?.label
        guard name != knownName else { return }
        take(name)
    }

    private mutating func take(_ name: String?) {
        knownName = name
        openingName = name
        emptied = false
    }
}
