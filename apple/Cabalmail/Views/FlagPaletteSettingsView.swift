import SwiftUI
import CabalmailKit

/// The custom-flag palette manager (rules-composition plan, Phase 3): up to
/// 20 named, colored flags on fixed slot atoms. All edits write straight
/// through `Preferences.flagPalette`, so the sync coordinator pushes them
/// like any other setting; renames and recolors are metadata edits that
/// touch zero messages.
struct FlagPaletteSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        SettingsForm(title: "Flags") {
            Section {
                ForEach(preferences.flagPalette) { entry in
                    // The whole row is one NavigationLink hit target — no
                    // nested controls, so the macOS single-target folding
                    // (#1299) has nothing to swallow.
                    NavigationLink {
                        FlagPaletteEntryEditor(preferences: preferences, slot: entry.slot)
                    } label: {
                        FlagPaletteRowLabel(entry: entry)
                    }
                }
                .onMove { source, destination in
                    var palette = preferences.flagPalette
                    palette.move(fromOffsets: source, toOffset: destination)
                    preferences.flagPalette = palette
                }
                Button {
                    addFlag()
                } label: {
                    Label("Add flag", systemImage: "plus")
                }
                .disabled(FlagPalette.firstFreeSlot(in: preferences.flagPalette) == nil)
            } footer: {
                Text(footerText)
                    .sectionFooter()
            }
        }
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private var footerText: String {
        preferences.flagPalette.isEmpty
            ? "Flags you define here can be put on any message from any of "
                + "your devices. Up to \(FlagPalette.maxEntries)."
            : "Drag to reorder; the order here is the order pickers use. "
                + "Up to \(FlagPalette.maxEntries) flags."
    }

    private func addFlag() {
        guard let slot = FlagPalette.firstFreeSlot(in: preferences.flagPalette) else { return }
        var palette = preferences.flagPalette
        palette.append(FlagPaletteEntry(
            slot: slot,
            label: "New flag",
            color: FlagPalette.colors.first ?? "gray"
        ))
        preferences.flagPalette = palette
    }
}

/// Color dot + label, shared by the list row and anywhere else a palette
/// entry needs naming.
struct FlagPaletteRowLabel: View {
    let entry: FlagPaletteEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.enabled ? "flag.fill" : "flag.slash")
                .foregroundStyle(FlagPaletteColor.color(for: entry.color))
            Text(entry.label)
                .foregroundStyle(entry.enabled ? .primary : .secondary)
        }
    }
}

/// Maps the wire color vocabulary onto SwiftUI colors. Unknown names (a
/// newer server's addition) render gray but round-trip unchanged.
enum FlagPaletteColor {
    static func color(for name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        default: .gray
        }
    }
}

/// Detail editor for one palette entry: label, color, enabled, and the only
/// route to deletion — which needs a confirmation, because per-message tags
/// on a retired slot outlive the palette entry.
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
                Toggle("Enabled", isOn: bindings.value(\.enabled, or: false))
            } footer: {
                Text("A disabled flag keeps its tags but is offered nowhere.")
                    .sectionFooter()
            }
            Section("Color") {
                colorGrid(selected: entry.color)
            }
            Section {
                Button("Delete Flag", role: .destructive) {
                    confirmingDelete = true
                }
                .confirmationDialog(
                    "Delete \u{201C}\(entry.label)\u{201D}?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Flag", role: .destructive) {
                        bindings.delete()
                        dismiss()
                    }
                } message: {
                    Text(
                        "Deleting a flag hides its name and color. Messages "
                        + "already tagged with it keep the tag (shown by its "
                        + "slot id) until untagged, and a new flag created "
                        + "later may reuse the slot."
                    )
                }
            }
        }
        .navigationTitle(entry.label)
        #if os(macOS)
        .formStyle(.grouped)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
