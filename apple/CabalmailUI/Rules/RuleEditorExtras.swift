import SwiftUI
import CabalmailKit

/// The independent extras of a rule — Flag, Mark as read, Forward, Reply.
/// Split from `RuleEditorView` so each type stays inside the lint body-length
/// budget. Everything here goes to the disabled state when the destination
/// is Delete (the handoff's "Delete locks down dependent fields": there is
/// no message left to flag, forward, or answer).
struct RuleExtrasSection: View {
    @Binding var rule: Rule
    /// The user's flag palette; the Flag extra is a picker of its entries
    /// (rules-composition plan, Phase 5), listed as Settings > Flags lists
    /// them (unified-flags plan, decision 7). Read from the environment
    /// like `FlagPaletteSettingsView` — the rules view model deliberately
    /// knows nothing about preferences.
    @Environment(Preferences.self) private var preferences

    /// The palette as Settings > Flags shows it, the built-in flag's entry
    /// included. On the wire the rule is unchanged: that entry's toggle is
    /// the rule's `flag`, and every other one a slot in its `flags`.
    private var palette: [FlagPaletteEntry] { FlagPalette.effective(preferences.flagPalette) }

    var body: some View {
        Section {
            Group {
                paletteToggles
                Toggle("Mark as read", isOn: $rule.markRead)
                forwardRows
                replyRows
            }
            .disabled(rule.action == .delete)
        } header: {
            FormSectionHeader {
                Text("Also")
            }
        } footer: {
            FormSectionFooter {
                if rule.action == .delete {
                    Text("These don't apply when the rule deletes the message.")
                        .sectionFooter()
                } else if rule.reply {
                    Text("Replies come from the address the message was sent to, at most once a week per sender.")
                        .sectionFooter()
                }
            }
        }
    }

    /// One toggle per enabled palette entry, in palette order, plus any slot
    /// this rule already sets whose entry is disabled or deleted — the
    /// compiler skips the rule while such a slot remains
    /// (`flag_not_in_palette`), so the stray toggle is the affordance for
    /// clearing it, labelled by slot id when the entry is gone.
    @ViewBuilder
    private var paletteToggles: some View {
        ForEach(pickerSlots, id: \.self) { slot in
            let entry = palette.first { $0.slot == slot }
            Toggle(isOn: slot == FlagPalette.systemSlot ? $rule.flag : slotBinding(slot)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(FlagPaletteColor.color(for: entry?.color ?? ""))
                        .frame(width: 10, height: 10)
                    Text(entry?.label ?? slot)
                }
            }
        }
    }

    /// The built-in flag is offered whatever its entry says: a rule can
    /// always set the server's flag, and the compiler never skips one for
    /// it (decision 7).
    private var pickerSlots: [String] {
        let offered = palette.filter { $0.enabled || $0.slot == FlagPalette.systemSlot }.map(\.slot)
        let stray = FlagPalette.slots
            .filter { rule.flags.contains($0) && !offered.contains($0) }
        return offered + stray
    }

    private func slotBinding(_ slot: String) -> Binding<Bool> {
        Binding(
            get: { rule.flags.contains(slot) },
            set: { isOn in
                if isOn {
                    if !rule.flags.contains(slot) { rule.flags.append(slot) }
                } else {
                    rule.flags.removeAll { $0 == slot }
                }
            }
        )
    }

    // No on/off toggle for Forward: the address list itself is the state —
    // one or more addresses means forward, none means don't.
    @ViewBuilder
    private var forwardRows: some View {
        ForwardAddressList(addresses: $rule.forward)
    }

    @ViewBuilder
    private var replyRows: some View {
        Toggle("Reply", isOn: $rule.reply)
        if rule.reply && rule.action != .delete {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $rule.replyBody)
                    .frame(minHeight: 120)
                    .appFont(.body)
                Text("\(rule.replyBody.unicodeScalars.count) / \(RulesValidator.maxReplyBodyLength)")
                    .appFont(.caption)
                    .foregroundStyle(
                        rule.replyBody.unicodeScalars.count > RulesValidator.maxReplyBodyLength
                            ? ColorTokens.dangerFg : .secondary
                    )
                if rule.replyBody.isEmpty {
                    Text("A reply needs some text.")
                        .appFont(.caption)
                        .foregroundStyle(ColorTokens.dangerFg)
                }
            }
        }
    }
}

/// The forward-address rows plus the add field. Addresses only land in the
/// rule when they pass the same shape check the server applies, so the
/// server's strip-at-PUT path stays unreachable from this editor.
private struct ForwardAddressList: View {
    @Binding var addresses: [String]
    @State private var newAddress = ""

    var body: some View {
        ForEach(addresses, id: \.self) { address in
            HStack {
                // Wrappable for the reason `FromPicker.fromLabel` gives (#1597).
                Text(AddressDisplay.wrappable(address))
                    .accessibilityLabel(address)
                Spacer()
                Button(role: .destructive) {
                    addresses.removeAll { $0 == address }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(ColorTokens.dangerFg)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(address)")
            }
        }
        if addresses.count < RulesValidator.maxForwards {
            HStack {
                TextField("Forward to address…", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textEntry(.email)
                    .onSubmit(addCurrent)
                Button("Add", action: addCurrent)
                    .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        let trimmed = newAddress.trimmingCharacters(in: .whitespaces)
        return RulesValidator.isValidForwardAddress(trimmed) && !addresses.contains(trimmed)
    }

    private func addCurrent() {
        guard canAdd else { return }
        addresses.append(newAddress.trimmingCharacters(in: .whitespaces))
        newAddress = ""
    }
}
