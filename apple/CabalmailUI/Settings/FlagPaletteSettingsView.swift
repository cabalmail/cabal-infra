import SwiftUI
import CabalmailKit

/// The flag palette manager: the system flag's entry, "Flagged" until the
/// user renames it, and up to 20 named, colored flags on fixed slot atoms
/// (rules-composition plan, Phase 3; unified-flags plan). All edits write
/// through `Preferences.flagPalette`, so the sync coordinator pushes them
/// like any other setting; renames and recolors are metadata edits that
/// touch zero messages.
///
/// The list is the effective palette (`FlagPalette.effective`), so the
/// system entry is always a row, whether or not it has been stored yet.
/// It renames, recolors and moves like the others, and resets where they
/// delete. No entry can be switched off: a flag is in the list or deleted.
///
/// The first entry is the default flag, the one the swipe, the flag
/// button and the flag shortcuts set (`FlagToggle`). Its row says so once
/// there is a second flag to tell it from, and every other row's context
/// menu offers Make Default, which moves that row to the top.
///
/// The order is the order pickers use. Rows move by Move Up / Move Down in
/// their context menu everywhere (the Mac's only route, since this grouped
/// form ignores `onMove` there) and by edit-mode drag on iOS and visionOS.
struct FlagPaletteSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        SettingsForm(title: "Flags") {
            Section {
                let palette = FlagPalette.effective(preferences.flagPalette)
                let defaultSlot = FlagPalette.defaultEntry(in: preferences.flagPalette).slot
                ForEach(palette) { entry in
                    // The whole row is one NavigationLink hit target — no
                    // nested controls, so the macOS single-target folding
                    // (#1299) has nothing to swallow. Move Up / Move Down
                    // ride on its context menu, outside the label: on the
                    // Mac that menu is the only way to reorder, because the
                    // grouped Settings form ignores `onMove` there (#2019).
                    NavigationLink {
                        FlagPaletteEntryEditor(preferences: preferences, slot: entry.slot)
                    } label: {
                        FlagPaletteRowLabel(
                            entry: entry,
                            isDefault: palette.count > 1 && entry.slot == defaultSlot
                        )
                    }
                    .contextMenu {
                        moveActions(for: entry.slot)
                    }
                }
                // Edit-mode drag on iOS and visionOS; inert in the Mac's
                // grouped form.
                .onMove { source, destination in
                    var palette = FlagPalette.effective(preferences.flagPalette)
                    palette.move(fromOffsets: source, toOffset: destination)
                    store(palette)
                }
                Button {
                    addFlag()
                } label: {
                    Label("Add flag", systemImage: "plus")
                }
                .disabled(FlagPalette.firstFreeSlot(in: preferences.flagPalette) == nil)
            } footer: {
                FormSectionFooter {
                    Text(Self.footerText(
                        paletteIsEmpty: FlagPalette.keywordEntries(in: preferences.flagPalette).isEmpty,
                        on: .current
                    ))
                    .sectionFooter()
                }
            }
        }
        .editButtonToolbar()
    }

    /// The footer under the palette: what the order means, how to change it
    /// on `host`, and which flag the one-press controls set. Drag is promised only where Edit offers it; on the Mac
    /// the grouped form ignores `onMove`, so it names the context menu.
    /// `paletteIsEmpty` is true while the user has added no flag of their
    /// own: the list then holds the built-in entry alone, and there is no
    /// order to explain. The count is of flags the user can add.
    static func footerText(paletteIsEmpty: Bool, on host: HostPlatform) -> String {
        if paletteIsEmpty {
            return "Flags you add here can be put on any message or feed item "
                + "from any of your devices. Up to \(FlagPalette.slots.count) of your own."
        }
        let reorder = host.reordersInEditMode
            ? "Tap Edit to drag flags into a new order"
            : "Right-click a flag to move it up or down"
        let makeDefault = host.reordersInEditMode
            ? "touch and hold another flag to make it the default"
            : "right-click another flag to make it the default"
        return reorder + "; the order here is the order pickers use. "
            + "A swipe, the flag button and the flag shortcut set the first flag, marked Default; "
            + makeDefault + ". "
            + "Up to \(FlagPalette.slots.count) flags of your own."
    }

    /// Make Default, then Move Up / Move Down, for one row, addressed by
    /// slot like the editor's bindings (#1340) rather than by a captured
    /// index.
    @ViewBuilder
    private func moveActions(for slot: String) -> some View {
        let bindings = FlagPaletteEntryBindings(preferences: preferences, slot: slot)
        Button {
            bindings.makeDefault()
        } label: {
            Label("Make Default", systemImage: "arrow.up.to.line")
        }
        .disabled(!bindings.canMakeDefault)
        Button {
            bindings.move(by: -1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!bindings.canMove(by: -1))
        Button {
            bindings.move(by: 1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!bindings.canMove(by: 1))
    }

    private func addFlag() {
        guard let slot = FlagPalette.firstFreeSlot(in: preferences.flagPalette) else { return }
        var palette = FlagPalette.effective(preferences.flagPalette)
        palette.append(FlagPaletteEntry(
            slot: slot,
            label: "New flag",
            color: FlagPalette.colors.first ?? "gray"
        ))
        store(palette)
    }

    /// Stores an edit to the list as shown, leaving the system entry off
    /// the wire while it is still the untouched default.
    private func store(_ edited: [FlagPaletteEntry]) {
        preferences.flagPalette = FlagPalette.stored(afterEditing: edited, from: preferences.flagPalette)
    }
}

/// Color dot + label, shared by the list row and anywhere else a palette
/// entry needs naming. `isDefault` adds the "Default" badge the list gives
/// the default flag's row.
struct FlagPaletteRowLabel: View {
    let entry: FlagPaletteEntry
    var isDefault = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.fill")
                .foregroundStyle(FlagPaletteColor.color(for: entry.color))
            Text(entry.label)
            if isDefault {
                Spacer(minLength: 8)
                Text("Default")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("flag.defaultBadge")
            }
        }
    }
}

/// Maps the wire color vocabulary onto the `flag.<name>` tokens. Unknown
/// names (a newer server's addition) render gray but round-trip unchanged;
/// the name is user data and never changes, only the value it draws in.
enum FlagPaletteColor {
    static func color(for name: String) -> Color {
        ColorTokens.flag(named: name)
    }
}

/// Detail editor for one palette entry: label, color, and the only route
/// to deletion — which needs a confirmation, because per-message tags on a
/// retired slot outlive the palette entry. The system flag's entry has no
/// deletion: it offers Reset to Default in its place, which needs no
/// confirmation, because it changes a name, a color and a position and
/// touches no message.
private struct FlagPaletteEntryEditor: View {
    let preferences: Preferences
    let slot: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    /// Every read and write in this editor goes through the slot, never a
    /// captured index — see `FlagPaletteEntryBindings` (#1340).
    private var bindings: FlagPaletteEntryBindings {
        FlagPaletteEntryBindings(preferences: preferences, slot: slot)
    }

    var body: some View {
        if let entry = bindings.entry {
            editor(entry)
        } else {
            // Deleted here or on another device while the editor was open.
            ContentUnavailableView("This flag was deleted", systemImage: "flag.slash")
        }
    }

    private func editor(_ entry: FlagPaletteEntry) -> some View {
        Form {
            Section {
                TextField("Name", text: bindings.label)
                    .autocorrectionDisabled()
            }
            Section(formHeader: "Color") {
                colorGrid(selected: entry.color)
            }
            if bindings.isSystemEntry {
                resetSection
            } else {
                deleteSection(entry)
            }
        }
        .navigationTitle(entry.label)
        .groupedFormStyleOnMac()
        .inlineNavigationTitle()
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Default") {
                bindings.reset()
            }
            .disabled(!bindings.canReset)
            .accessibilityIdentifier("flag.resetToDefault")
        } footer: {
            FormSectionFooter {
                Text(
                    "This flag is built in and can't be deleted. Resetting gives it back "
                    + "its original name and color and returns it to the top of the list."
                )
                .sectionFooter()
            }
        }
    }

    private func deleteSection(_ entry: FlagPaletteEntry) -> some View {
        Section {
            Button("Delete Flag", role: .destructive) {
                confirmingDelete = true
            }
            .confirmationPrompt(
                "Delete \u{201C}\(entry.label)\u{201D}?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Flag", role: .destructive) {
                    bindings.delete()
                    dismiss()
                }
                Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
            } message: {
                Text(
                    "Deleting a flag hides its name and color. Messages "
                    + "and feed items already tagged with it keep the tag "
                    + "(shown by its slot id) until untagged, and a new "
                    + "flag created later may reuse the slot."
                )
            }
        }
    }

    private func colorGrid(selected: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
            ForEach(FlagPalette.colors, id: \.self) { name in
                Button {
                    bindings.set(\.color, to: name)
                } label: {
                    ZStack {
                        Circle()
                            .fill(FlagPaletteColor.color(for: name))
                            .frame(width: 32, height: 32)
                        if name == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                // Without an explicit identifier the selected swatch inherits
                // one from the decorative checkmark nested in its `ZStack`,
                // so exactly one swatch answers to `checkmark` and the other
                // nine to nothing at all (#1341).
                .accessibilityIdentifier("flag.color.\(name)")
                .accessibilityAddTraits(name == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
