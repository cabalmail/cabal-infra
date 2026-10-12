import SwiftUI
import CabalmailKit

/// Mail-rules editor entry point (`docs/1.x/user-mail-rules-plan.md`,
/// Phase 4): the ordered rule list with reorder / enable / add / duplicate /
/// delete, pushing `RuleEditorView` for the detail form.
///
/// Reached as the Rules category's detail screen in Settings on every
/// platform — the category row leads straight here, and the detail column's
/// `NavigationStack` hosts the editor pushes (including on macOS, where the
/// stack-less Settings scene used to require a sheet-hosted stack instead).
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
        .inlineNavigationTitle()
        .task {
            // Building the model and loading it are separate questions: on
            // iPhone the pushed destination is built, torn down and rebuilt
            // during the navigation transition, and the `@State` survives.
            // Gating the load on `model == nil` therefore stranded the
            // cancelled first attempt's error on screen forever (#1328), so
            // the load is gated on the model's own attempt flag instead.
            let target: RulesViewModel
            if let model {
                target = model
            } else {
                guard let client = appState.client else { return }
                target = RulesViewModel(backend: LiveRulesBackend(client: client))
                model = target
            }
            guard !target.hasAttemptedLoad else { return }
            await target.load()
        }
    }

    /// The rules list's footer: what the order means, then how to change it
    /// on `host`. Edit and drag where lists have an edit mode; on the Mac,
    /// whose grouped Settings form ignores `onMove`, the row's menus.
    static func listFooter(on host: HostPlatform) -> String {
        let reorder = host.reordersInEditMode
            ? "Tap Edit to drag rules into a new order."
            : "To move a rule up or down, right-click it or use its ⋯ menu."
        return "Rules run top to bottom on every arriving message; "
            + "the first match applies unless it continues to the next rule. "
            + reorder
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
        .editButtonToolbar()
        .safeAreaInset(edge: .bottom) { RulesSaveStatusBar(model: model) }
        .alert("Rules updated on another device", isPresented: $model.conflict) {
            Button("Reload") { Task { await model.load() } }
        } message: {
            Text("Reload to see the latest rules. Changes you made here that didn't save will be lost.")
        }
    }

    /// A grouped `Form`, as every other Settings category is (`SettingsForm`),
    /// rather than a list. On the Mac only the grouped form draws the
    /// System Settings look: rows on a card and no separator under the last
    /// row. A bare list put the rows on the window background and drew a
    /// line under "Add rule" (#2019); its Enabled toggles drew as checkboxes,
    /// which `RuleRow.enabledToggle` now styles as the form's mini switch
    /// whatever its container. Not `SettingsForm` itself, because
    /// `RulesView` already titles the screen for the loading and empty
    /// states too.
    ///
    /// The cost is drag on the Mac: a grouped form there ignores `onMove`
    /// (Flags never dragged either), so the Mac reorders with Move Up / Move
    /// Down in each row's menus (`RuleRow.rowActions`). iOS and visionOS
    /// forms are list-backed, so `onMove` and `onDelete` keep working there
    /// in edit mode and by swipe, as Flags' `onMove` already does in a Form.
    private var rulesList: some View {
        Form {
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
                // Add sits at the foot of the list on every platform, as
                // "Add flag" does in the Flags screen, rather than as a
                // toolbar "+" (which never rendered reliably in the macOS
                // Settings window either). Delete is on the rows (see
                // RuleRow).
                Button {
                    model.add()
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .disabled(model.rules.count >= RulesValidator.maxRules)
            } footer: {
                Text(RulesView.listFooter(on: .current))
                    .sectionFooter()
            }
        }
        .groupedFormStyleOnMac()
    }
}

private struct RuleRow: View {
    @Bindable var model: RulesViewModel
    let rule: Rule

    var body: some View {
        #if os(macOS)
        // A NavigationLink's label is one hit target on macOS: controls
        // nested inside it stop taking clicks (SwiftUI folds them into the
        // link as accessibility custom actions), so every click in the row
        // pushed the editor instead of hitting the toggle or the menu
        // (#1299). Both therefore sit beside the link, not in its label;
        // the switch trailing, where the grouped form puts every other
        // Settings switch.
        HStack(spacing: 12) {
            NavigationLink {
                RuleEditorView(model: model, ruleID: rule.id)
            } label: {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            enabledToggle
            // Visible stand-in for the context menu below: right-click
            // is the only other route to Move/Duplicate/Delete on macOS,
            // and only the footer mentions it (for Move), so without this
            // menu Duplicate and Delete would have no visible way in.
            Menu {
                rowActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contextMenu {
            rowActions
        }
        #else
        NavigationLink {
            RuleEditorView(model: model, ruleID: rule.id)
        } label: {
            HStack(spacing: 12) {
                enabledToggle
                summary
            }
        }
        .contextMenu {
            rowActions
        }
        #endif
    }

    private var enabledToggle: some View {
        Toggle("Enabled", isOn: Binding(
            get: { rule.enabled },
            set: { model.setEnabled(rule.id, $0) }
        ))
        .labelsHidden()
        // The grouped form's mini switch on the Mac, where an automatic
        // toggle sharing its row drew a checkbox in the old list. iOS and
        // visionOS draw this switch already.
        .miniSwitchStyleOnMac()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                .foregroundStyle(rule.enabled ? .primary : .secondary)
            Text(RuleSummary.describe(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// Shared by the Mac's ⋯ menu and every platform's context menu. Move
    /// Up / Move Down are the Mac's only way to reorder, since its grouped
    /// Settings form ignores `onMove`; elsewhere they sit beside Edit's drag.
    @ViewBuilder
    private var rowActions: some View {
        Button {
            model.move(id: rule.id, by: -1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!model.canMove(id: rule.id, by: -1))
        Button {
            model.move(id: rule.id, by: 1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!model.canMove(id: rule.id, by: 1))
        Divider()
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
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ColorTokens.successFg)
                    statusText("Saved")
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ColorTokens.dangerFg)
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
        var parts = [conditionsPhrase(rule.conditions)]
        // A continuing None rule neither files nor stops; "no filing" would
        // just be noise, so a decorate-only rule reads "flag · continue".
        if !(rule.action == .none && rule.continueToNext) {
            parts.append(actionPhrase(rule))
        }
        if rule.flag { parts.append("flag") }
        // Custom flags by count: the summary is pure (no palette access),
        // so labels can't resolve here — the editor shows them.
        if !rule.flags.isEmpty {
            parts.append(rule.flags.count == 1
                ? "1 custom flag" : "\(rule.flags.count) custom flags")
        }
        if rule.markRead { parts.append("mark read") }
        if !rule.forward.isEmpty { parts.append("forward to \(rule.forward.joined(separator: ", "))") }
        if rule.reply { parts.append("reply") }
        // "continue" last, so a spill-through rule reads as what it is:
        // "copy to Receipts · continue" (truthful Continue, Phase 1).
        if rule.continueToNext { parts.append("continue") }
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
