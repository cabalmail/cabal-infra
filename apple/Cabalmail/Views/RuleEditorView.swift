import SwiftUI
import CabalmailKit

/// Detail form for one mail rule: name, spill-through, conditions, the
/// mutually-exclusive destination, and the independent extras (flag / mark
/// read / forward / reply). Every control writes through
/// `RulesViewModel.update`, which schedules the debounced whole-set save.
///
/// Spill-through leads the form and gates the destination (truthful
/// Continue, `docs/1.x/rules-composition-and-custom-flags-plan.md` decision
/// 1): a continuing rule passes the message along, so any delivery it makes
/// is a copy — Move and Archive are disabled in place while Continue is on,
/// and turning Continue on converts them to Copy (identical compiled
/// output, so a conversion is a relabel, not a behavior change).
struct RuleEditorView: View {
    @Bindable var model: RulesViewModel
    let ruleID: String
    /// Inline note shown after Continue-on auto-converts Move/Archive to
    /// Copy; cleared when the user picks a destination or turns Continue off.
    @State private var conversionNote: String?

    var body: some View {
        if model.rule(withID: ruleID) == nil {
            // Deleted from the list (or on another device) while the editor
            // was open.
            ContentUnavailableView(
                "This rule was deleted",
                systemImage: "list.bullet.rectangle"
            )
        } else {
            editor
        }
    }

    private var editor: some View {
        Form {
            Section {
                TextField("Name", text: rule.name)
                Toggle("Enabled", isOn: rule.enabled)
            }
            Section {
                Toggle("Continue to the next rule", isOn: continueBinding)
                    .disabled(isDelete)
            } footer: {
                Text(isDelete
                    ? "A deleted message can't continue to later rules."
                    : "Off: the first matching rule is the last one that runs. On: later rules still see this message.")
                    .sectionFooter()
            }
            RuleConditionsSection(rule: rule)
            RuleDestinationSection(model: model, rule: rule, conversionNote: $conversionNote)
            RuleExtrasSection(rule: rule)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(model.rule(withID: ruleID)?.name ?? "Rule")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var isDelete: Bool {
        model.rule(withID: ruleID)?.action == .delete
    }

    /// Write-through binding into the model; the getter's fallback only
    /// exists for the frame where the rule disappears mid-render.
    private var rule: Binding<Rule> {
        Binding(
            get: { model.rule(withID: ruleID) ?? Rule(id: ruleID) },
            set: { model.update($0) }
        )
    }

    /// The Continue toggle's write path: turning it on while Move or Archive
    /// is selected converts the destination to Copy, carrying the folder.
    private var continueBinding: Binding<Bool> {
        Binding(
            get: { model.rule(withID: ruleID)?.continueToNext ?? false },
            set: { isOn in
                guard var updated = model.rule(withID: ruleID) else { return }
                updated.continueToNext = isOn
                if isOn, updated.action == .move || updated.action == .archive {
                    let from = updated.action == .move ? "Move" : "Archive"
                    conversionNote = "\(from) changed to Copy: a continuing rule "
                        + "delivers a copy and passes the message along."
                    updated = updated.normalizingLegacyContinue()
                } else {
                    conversionNote = nil
                }
                model.update(updated)
            }
        )
    }
}

/// The ANDed condition rows: field picker + contains-value text field.
private struct RuleConditionsSection: View {
    @Binding var rule: Rule

    var body: some View {
        Section {
            ForEach($rule.conditions) { $condition in
                HStack {
                    Picker("Field", selection: $condition.field) {
                        ForEach(Rule.Field.allCases, id: \.self) { field in
                            Text(label(for: field)).tag(field)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110, alignment: .leading)
                    TextField("contains…", text: $condition.value)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button(role: .destructive) {
                        rule.conditions.removeAll { $0.id == condition.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove condition")
                }
            }
            Button {
                rule.conditions.append(Rule.Condition())
            } label: {
                Label("Add condition", systemImage: "plus.circle")
            }
            .disabled(rule.conditions.count >= RulesValidator.maxConditions)
        } header: {
            Text("Conditions")
        } footer: {
            Text(rule.conditions.isEmpty
                ? "No conditions: this rule matches every message."
                : "All conditions must match (case-insensitive contains).")
                .sectionFooter()
        }
    }

    private func label(for field: Rule.Field) -> String {
        switch field {
        case .from: return "From"
        case .to: return "To"
        case .cc: return "Cc"
        case .subject: return "Subject"
        case .body: return "Body"
        }
    }
}

/// The mutually-exclusive destination and its folder pickers. Pickers offer
/// only folders that already exist — no free text, no create affordance
/// (the plan's "No folder auto-creation"); the one accommodation is the
/// explicit Create Archive Folder prompt for the Archive action.
///
/// One row per option rather than a segmented control: while Continue is on,
/// Move / Archive / Delete must render disabled in place (not hidden), which
/// segments can't do.
private struct RuleDestinationSection: View {
    @Bindable var model: RulesViewModel
    @Binding var rule: Rule
    @Binding var conversionNote: String?
    @State private var archiveCreateFailed = false

    private static let choices: [(action: Rule.Action, label: String)] = [
        (.move, "Move"),
        (.copy, "Copy"),
        (.archive, "Archive"),
        (.delete, "Delete"),
        (.none, "None"),
    ]

    var body: some View {
        Section {
            ForEach(Self.choices, id: \.action) { choice in
                destinationRow(choice.action, choice.label)
            }
            destinationDetail
            if RulesValidator.hasNoEffect(rule) {
                Text(
                    "This rule would have no effect: it continues to the "
                    + "next rule without filing, forwarding, or replying."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        } header: {
            Text("Destination")
        } footer: {
            footerText
                .sectionFooter()
        }
    }

    private func destinationRow(_ action: Rule.Action, _ label: String) -> some View {
        let gated = isGated(action)
        return Button {
            conversionNote = nil
            rule.action = action
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(gated ? Color.secondary : Color.primary)
                Spacer()
                if rule.action == action {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(gated)
        .accessibilityAddTraits(rule.action == action ? .isSelected : [])
    }

    /// Decision 1's gate: a continuing rule can only Copy or None. Move and
    /// Archive are disabled because their spill-through compilation *is*
    /// Copy; Delete because the engine ignores Continue on Delete.
    private func isGated(_ action: Rule.Action) -> Bool {
        rule.continueToNext
            && (action == .move || action == .archive || action == .delete)
    }

    @ViewBuilder
    private var destinationDetail: some View {
        switch rule.action {
        case .move:
            Picker("Folder", selection: $rule.moveFolder) {
                Text("Choose a folder…").tag("")
                // A stored target whose folder was deleted stays selectable
                // (and flagged in the footer) instead of silently resetting.
                if !rule.moveFolder.isEmpty && !folderExists(rule.moveFolder) {
                    Text("\(rule.moveFolder) (missing)").tag(rule.moveFolder)
                }
                ForEach(model.folders) { folder in
                    Text(folder.path).tag(folder.path)
                }
            }
        case .copy:
            NavigationLink {
                CopyFoldersPicker(model: model, selection: $rule.copyFolders)
            } label: {
                LabeledContent("Folders") {
                    Text(rule.copyFolders.isEmpty
                        ? "Choose…" : rule.copyFolders.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
        case .archive where !model.hasArchiveFolder:
            VStack(alignment: .leading, spacing: 6) {
                Text("You don't have an Archive folder yet, so this rule would be skipped.")
                    .font(.callout)
                Button("Create Archive Folder") {
                    archiveCreateFailed = false
                    Task { archiveCreateFailed = !(await model.createArchiveFolder()) }
                }
                if archiveCreateFailed {
                    Text("Couldn't create the folder. Try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .archive, .delete, .none:
            EmptyView()
        }
    }

    private var footerText: Text? {
        var lines: [String] = []
        if let conversionNote {
            lines.append(conversionNote)
        }
        if rule.continueToNext {
            lines.append("A rule that continues passes the message along; use Copy.")
        }
        switch rule.action {
        case .move where !rule.moveFolder.isEmpty && !folderExists(rule.moveFolder):
            lines.append(
                "That folder no longer exists; the rule is skipped until "
                + "you pick another (mail stays in the inbox)."
            )
        case .delete:
            lines.append("Deleted messages are discarded permanently at delivery, not moved to Trash.")
        case .none:
            lines.append(rule.continueToNext
                ? "The message passes to later rules; if none files it, it lands in the inbox."
                : "The message stays in the inbox; the actions below still apply.")
        default:
            break
        }
        return lines.isEmpty ? nil : Text(lines.joined(separator: "\n"))
    }

    private func folderExists(_ path: String) -> Bool {
        // An empty list usually means the folder fetch failed; don't cry
        // wolf about every stored target in that case.
        model.folders.isEmpty || model.folders.contains { $0.path == path }
    }
}

/// Multi-select folder list for the Copy destination.
private struct CopyFoldersPicker: View {
    @Bindable var model: RulesViewModel
    @Binding var selection: [String]

    var body: some View {
        List(model.folders) { folder in
            Button {
                toggle(folder.path)
            } label: {
                HStack {
                    Text(folder.path)
                    Spacer()
                    if selection.contains(folder.path) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selection.contains(folder.path)
                && selection.count >= RulesValidator.maxCopyFolders)
        }
        .navigationTitle("Copy to folders")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func toggle(_ path: String) {
        if let index = selection.firstIndex(of: path) {
            selection.remove(at: index)
        } else {
            selection.append(path)
        }
    }
}
