import SwiftUI
import CabalmailKit

/// The independent extras of a rule — Flag, Mark as read, Forward, Reply.
/// Split from `RuleEditorView` so each type stays inside the lint body-length
/// budget. Everything here goes to the disabled state when the destination
/// is Delete (the handoff's "Delete locks down dependent fields": there is
/// no message left to flag, forward, or answer).
struct RuleExtrasSection: View {
    @Binding var rule: Rule
    /// The user's custom-flag palette; the Flag extra grew into a picker of
    /// the classic flag plus these (rules-composition plan, Phase 5). Read
    /// from the environment like `FlagPaletteSettingsView` — the rules view
    /// model deliberately knows nothing about preferences.
    @Environment(Preferences.self) private var preferences

    private var palette: [FlagPaletteEntry] { preferences.flagPalette }

    var body: some View {
        Section {
            Group {
                Toggle("Flag", isOn: $rule.flag)
                paletteToggles
                Toggle("Mark as read", isOn: $rule.markRead)
                forwardRows
                replyRows
            }
            .disabled(rule.action == .delete)
        } header: {
            Text("Also")
        } footer: {
            if rule.action == .delete {
                Text("These don't apply when the rule deletes the message.")
                    .sectionFooter()
            } else if rule.reply {
                Text("Replies come from the address the message was sent to, at most once a week per sender.")
                    .sectionFooter()
            }
        }
    }

    /// One toggle per enabled palette entry, plus any slot this rule already
    /// sets whose entry is disabled or deleted — the compiler skips the rule
    /// while such a slot remains (`flag_not_in_palette`), so the stray
    /// toggle is the affordance for clearing it, labelled by slot id when
    /// the entry is gone.
    @ViewBuilder
    private var paletteToggles: some View {
        ForEach(pickerSlots, id: \.self) { slot in
            let entry = palette.first { $0.slot == slot }
            Toggle(isOn: slotBinding(slot)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(FlagPaletteColor.color(for: entry?.color ?? ""))
                        .frame(width: 10, height: 10)
                    Text(entry?.label ?? slot)
                }
            }
        }
    }

    private var pickerSlots: [String] {
        let offered = palette.filter(\.enabled).map(\.slot)
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
                    .font(.body)
                Text("\(rule.replyBody.unicodeScalars.count) / \(RulesValidator.maxReplyBodyLength)")
                    .font(.caption)
                    .foregroundStyle(
                        rule.replyBody.unicodeScalars.count > RulesValidator.maxReplyBodyLength
                            ? .red : .secondary
                    )
                if rule.replyBody.isEmpty {
                    Text("A reply needs some text.")
                        .font(.caption)
                        .foregroundStyle(.red)
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
                Text(address)
                Spacer()
                Button(role: .destructive) {
                    addresses.removeAll { $0 == address }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
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
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
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
