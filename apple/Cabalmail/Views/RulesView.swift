import SwiftUI
import CabalmailKit

/// Mail-rules editor entry point (`docs/1.x/user-mail-rules-plan.md`,
/// Phase 4): the ordered rule list with reorder / enable / add / duplicate /
/// delete, pushing `RuleEditorView` for the detail form.
///
/// Reached as a push from the Settings form on iOS / iPadOS / visionOS and
/// inside a sheet-hosted `NavigationStack` from the macOS Settings window
/// (the Settings scene has no stack of its own, so a push there is inert —
/// same pattern as the Acknowledgements sheet).
struct RulesView: View {
    @Environment(AppState.self) private var appState
    @State private var model: RulesViewModel?

    var body: some View {
        Group {
            if let model {
                RulesListView(model: model)
            } else {
                ProgressView("Loading rules…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Mail rules")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard model == nil, let client = appState.client else { return }
            let fresh = RulesViewModel(backend: LiveRulesBackend(client: client))
            model = fresh
            await fresh.load()
        }
    }
}

/// The loaded list: master side of the master/detail flow.
private struct RulesListView: View {
    @Bindable var model: RulesViewModel

    var body: some View {
        AsyncContentView(
            isLoading: model.isLoading,
            loadingLabel: "Loading rules…",
            errorMessage: model.loadError,
            retry: { Task { await model.load() } },
            content: {
                if model.rules.isEmpty {
                    RulesEmptyState(model: model)
                } else {
                    rulesList
                }
            }
        )
        .toolbar {
            #if os(iOS) || os(visionOS)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.add()
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .disabled(model.rules.count >= RulesValidator.maxRules)
            }
        }
        .safeAreaInset(edge: .bottom) { RulesSaveStatusBar(model: model) }
        .alert("Rules updated on another device", isPresented: $model.conflict) {
            Button("Reload") { Task { await model.load() } }
        } message: {
            Text("Reload to see the latest rules. Changes you made here that didn't save will be lost.")
        }
    }

    private var rulesList: some View {
        List {
            Section {
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
                .onMove { source, destination in
                    model.move(from: source, to: destination)
                }
                .onDelete { offsets in
                    model.delete(at: offsets)
                }
                #if os(macOS)
                // The toolbar "+" doesn't reliably render in the Settings
                // sheet, and swipe/EditButton deletion doesn't exist on
                // macOS — the list itself must carry the affordances (the
                // rows carry delete; see RuleRow).
                Button {
                    model.add()
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .disabled(model.rules.count >= RulesValidator.maxRules)
                #endif
            } footer: {
                Text(
                    "Rules run top to bottom on every arriving message; "
                    + "the first match applies unless it continues to the next rule."
                )
            }
        }
    }
}

private struct RuleRow: View {
    @Bindable var model: RulesViewModel
    let rule: Rule

    var body: some View {
        NavigationLink {
            RuleEditorView(model: model, ruleID: rule.id)
        } label: {
            HStack(spacing: 12) {
                Toggle("Enabled", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.setEnabled(rule.id, $0) }
                ))
                .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    Text(RuleSummary.describe(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                #if os(macOS)
                // Visible stand-in for the context menu below: right-click
                // is the only other route to Duplicate/Delete on macOS,
                // and nothing advertises it.
                Spacer()
                Menu {
                    rowActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                #endif
            }
        }
        .contextMenu {
            rowActions
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        Button {
            model.duplicate(rule.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            model.delete(id: rule.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// The auto-save indicator: the plan's idle / saving / saved / error state
/// machine, with Retry on error.
private struct RulesSaveStatusBar: View {
    @Bindable var model: RulesViewModel

    var body: some View {
        if model.saveState != .idle {
            HStack(spacing: 8) {
                switch model.saveState {
                case .idle:
                    EmptyView()
                case .saving:
                    ProgressView().controlSize(.small)
                    statusText("Saving…")
                case .saved:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    statusText("Saved")
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    statusText(message)
                    Button("Retry") { model.retrySave() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// First-run screen: the plan's three starter templates plus a blank rule.
/// Templates arrive disabled with their destination (or sender, or reply
/// text) left for the user — a template never names a folder that may not
/// exist and never creates one.
private struct RulesEmptyState: View {
    @Bindable var model: RulesViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No rules yet")
                    .font(.title3.weight(.semibold))
                Text(
                    "Rules file, flag, forward, or answer incoming mail for you. "
                    + "Start from a template or a blank rule."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    templateButton(
                        "File AWS receipts",
                        subtitle: "Move mail from aws.amazon.com to a folder you pick",
                        template: RuleTemplates.fileReceipts()
                    )
                    templateButton(
                        "Mute a newsletter",
                        subtitle: "Archive a sender's mail already marked read",
                        template: RuleTemplates.muteNewsletter()
                    )
                    templateButton(
                        "Vacation reply",
                        subtitle: "Answer every message with an away note",
                        template: RuleTemplates.vacationReply()
                    )
                }
                Button("Start with a blank rule") {
                    model.add()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private func templateButton(_ title: String, subtitle: String, template: Rule) -> some View {
        Button {
            model.add(template)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }
}

/// The plan's quick-start templates. All start disabled: each needs a user
/// decision (a destination folder, the real sender, the reply wording)
/// before it should act on mail.
enum RuleTemplates {
    static func fileReceipts() -> Rule {
        Rule(
            name: "File AWS receipts",
            enabled: false,
            conditions: [Rule.Condition(field: .from, value: "aws.amazon.com")],
            action: .move
        )
    }

    static func muteNewsletter() -> Rule {
        Rule(
            name: "Mute a newsletter",
            enabled: false,
            conditions: [Rule.Condition(field: .from, value: "newsletter@example.com")],
            action: .archive,
            markRead: true
        )
    }

    static func vacationReply() -> Rule {
        Rule(
            name: "Vacation reply",
            enabled: false,
            reply: true,
            replyBody: "I'm away right now and will reply when I return."
        )
    }
}

/// One-line rule summary for the list rows, in the spirit of the design
/// handoff's `describeRule`.
enum RuleSummary {
    static func describe(_ rule: Rule) -> String {
        var parts = [conditionsPhrase(rule.conditions), actionPhrase(rule)]
        if rule.flag { parts.append("flag") }
        if rule.markRead { parts.append("mark read") }
        if !rule.forward.isEmpty { parts.append("forward to \(rule.forward.joined(separator: ", "))") }
        if rule.reply { parts.append("reply") }
        if rule.continueToNext { parts.append("continue to next rule") }
        return parts.joined(separator: " · ")
    }

    private static func conditionsPhrase(_ conditions: [Rule.Condition]) -> String {
        guard let first = conditions.first else { return "Every message" }
        let phrase = "\(fieldName(first.field)) contains “\(first.value)”"
        let rest = conditions.count - 1
        return rest > 0 ? "\(phrase) + \(rest) more" : phrase
    }

    private static func actionPhrase(_ rule: Rule) -> String {
        switch rule.action {
        case .move:
            return rule.moveFolder.isEmpty
                ? "move (pick a folder)" : "move to \(rule.moveFolder)"
        case .copy:
            return rule.copyFolders.isEmpty
                ? "copy (pick folders)" : "copy to \(rule.copyFolders.joined(separator: ", "))"
        case .delete:
            return "delete"
        case .archive:
            return "archive"
        case .none:
            return "no filing"
        }
    }

    private static func fieldName(_ field: Rule.Field) -> String {
        switch field {
        case .from: return "From"
        case .to: return "To"
        case .cc: return "Cc"
        case .subject: return "Subject"
        case .body: return "Body"
        }
    }
}
