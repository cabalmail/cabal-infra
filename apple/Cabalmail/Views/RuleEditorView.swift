import SwiftUI
import CabalmailKit

/// Detail form for one mail rule: name, conditions, the mutually-exclusive
/// destination, the independent extras (flag / mark read / forward / reply),
/// and spill-through. Every control writes through `RulesViewModel.update`,
/// which schedules the debounced whole-set save.
struct RuleEditorView: View {
    @Bindable var model: RulesViewModel
    let ruleID: String

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
            RuleConditionsSection(rule: rule)
            RuleDestinationSection(model: model, rule: rule)
            RuleExtrasSection(rule: rule)
            Section {
                Toggle("Continue to the next rule", isOn: rule.continueToNext)
                    .disabled(isDelete)
            } footer: {
                Text(isDelete
                    ? "A deleted message can't continue to later rules."
                    : "Off: the first matching rule is the last one that runs. On: later rules still see this message.")
                    .sectionFooter()
            }
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
private struct RuleDestinationSection: View {
    @Bindable var model: RulesViewModel
    @Binding var rule: Rule
    @State private var archiveCreateFailed = false

    var body: some View {
        Section {
            Picker("Destination", selection: $rule.action) {
                Text("Move").tag(Rule.Action.move)
                Text("Copy").tag(Rule.Action.copy)
                Text("Archive").tag(Rule.Action.archive)
                Text("Delete").tag(Rule.Action.delete)
                Text("None").tag(Rule.Action.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            destinationDetail
        } header: {
            Text("Destination")
        } footer: {
            footerText
                .sectionFooter()
        }
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
        switch rule.action {
        case .move where !rule.moveFolder.isEmpty && !folderExists(rule.moveFolder):
            return Text(
                "That folder no longer exists; the rule is skipped until "
                + "you pick another (mail stays in the inbox)."
            )
        case .delete:
            return Text("Deleted messages are discarded permanently at delivery, not moved to Trash.")
        case .none:
            return Text("The message stays in the inbox; the actions below still apply.")
        default:
            return nil
        }
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
