import SwiftUI
import CabalmailKit

/// The independent extras of a rule — Flag, Mark as read, Forward, Reply.
/// Split from `RuleEditorView` so each type stays inside the lint body-length
/// budget. Everything here goes to the disabled state when the destination
/// is Delete (the handoff's "Delete locks down dependent fields": there is
/// no message left to flag, forward, or answer).
struct RuleExtrasSection: View {
    @Binding var rule: Rule

    var body: some View {
        Section {
            Group {
                // The Flag extra: one switch per flag in Settings > Flags
                // (rules-composition plan, Phase 5).
                RuleFlagToggles(flag: $rule.flag, flags: $rule.flags)
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
