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
    @Bindable var preferences: Preferences
    let slot: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        if let index = preferences.flagPalette.firstIndex(where: { $0.slot == slot }) {
            editor(at: index)
        } else {
            // Deleted here or on another device while the editor was open.
            ContentUnavailableView("This flag was deleted", systemImage: "flag.slash")
        }
    }

    private func editor(at index: Int) -> some View {
        let entry = preferences.flagPalette[index]
        return Form {
            Section {
                TextField("Name", text: labelBinding(at: index))
                    .autocorrectionDisabled()
                Toggle("Enabled", isOn: binding(at: index, \.enabled))
            } footer: {
                Text("A disabled flag keeps its tags but is offered nowhere.")
                    .sectionFooter()
            }
            Section("Color") {
                colorGrid(at: index, selected: entry.color)
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
                        preferences.flagPalette.removeAll { $0.slot == slot }
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

    private func colorGrid(at index: Int, selected: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
            ForEach(FlagPalette.colors, id: \.self) { name in
                Button {
                    preferences.flagPalette[index].color = name
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
                .accessibilityAddTraits(name == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    /// Label writes are capped to the server's length limit as they are
    /// typed. A momentarily empty label (mid-edit) stays local: the server
    /// rejects it, the push silently retries on the next keystroke, and
    /// nothing is lost — the same transient-invalid posture the reply-body
    /// editor takes.
    private func labelBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { preferences.flagPalette[index].label },
            set: { newValue in
                preferences.flagPalette[index].label =
                    String(newValue.prefix(FlagPalette.maxLabelLength))
            }
        )
    }

    private func binding<Value>(
        at index: Int, _ keyPath: WritableKeyPath<FlagPaletteEntry, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences.flagPalette[index][keyPath: keyPath] },
            set: { preferences.flagPalette[index][keyPath: keyPath] = $0 }
        )
    }
}
