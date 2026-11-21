import SwiftUI
import CabalmailKit

/// Rules editor entry point (`docs/1.x/user-mail-rules-plan.md`, Phase 4,
/// and `docs/1.x/cross-media-ux-plan.md`, Phase 4): the ordered mail rule
/// list and, in a section after it, the feed rules, each with reorder /
/// enable / add / duplicate / delete, pushing `RuleEditorView` or
/// `FeedRuleEditorView` for the detail form.
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
        .navigationTitle("Rules")
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

    /// The feed rules' footer. It says nothing about order because there is
    /// none to explain: nothing is filed, so every matching rule applies.
    static let feedListFooter = "Every enabled rule that matches applies to a new item "
        + "when its feed is fetched, before you open the feed. Order doesn't matter."
}

/// The loaded list: master side of the master/detail flow.
private struct RulesListView: View {
    @Bindable var model: RulesViewModel
    /// The rule Add just made, pushed into the editor. The rows push the
    /// editor through their own `NavigationLink`; adding has no link to
    /// follow, so it pushes by value instead (#2031).
    @State private var addedRuleID: String?
    /// The same for a feed rule, which has an editor of its own.
    @State private var addedFeedRuleID: String?

    var body: some View {
        AsyncContentView(
            isLoading: model.isLoading,
            loadingLabel: "Loading rules…",
            errorMessage: model.loadError,
            retry: { Task { await model.load() } },
            content: {
                if model.rules.isEmpty && model.feed.rules.isEmpty {
                    RulesEmptyState(
                        model: model, addedRuleID: $addedRuleID, addedFeedRuleID: $addedFeedRuleID
                    )
                } else {
                    rulesList
                }
            }
        )
        .navigationDestination(item: $addedRuleID) { id in
            RuleEditorView(model: model, ruleID: id)
        }
        .navigationDestination(item: $addedFeedRuleID) { id in
            FeedRuleEditorView(model: model.feed, ruleID: id)
        }
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
    ///
    /// Two sections of the one form: the mail rules, then the feed rules
    /// (`cross-media-ux-plan.md`, Phase 4). Each list reorders and deletes
    /// within itself.
    private var rulesList: some View {
        Form {
            mailSection
            feedSection
        }
        .groupedFormStyleOnMac()
    }

    private var mailSection: some View {
        Section {
            ForEach(model.rules) { rule in
                RuleRow(
                    item: RuleRowItem(rule),
                    actions: RuleRowActions(
                        setEnabled: { model.setEnabled(rule.id, $0) },
                        move: { model.move(id: rule.id, by: $0) },
                        canMove: { model.canMove(id: rule.id, by: $0) },
                        duplicate: { model.duplicate(rule.id) },
                        delete: { model.delete(id: rule.id) }
                    ),
                    editor: { RuleEditorView(model: model, ruleID: rule.id) }
                )
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
                addedRuleID = model.add()
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .disabled(model.rules.count >= RulesValidator.maxRules)
        } header: {
            FormSectionHeader {
                Text("Email messages")
            }
        } footer: {
            FormSectionFooter {
                Text(RulesView.listFooter(on: .current))
                    .sectionFooter()
            }
        }
    }

    private var feedSection: some View {
        Section {
            ForEach(model.feed.rules) { rule in
                RuleRow(
                    item: RuleRowItem(rule, feedTitle: feedTitle(of: rule)),
                    actions: RuleRowActions(
                        setEnabled: { model.feed.setEnabled(rule.id, $0) },
                        move: { model.feed.move(id: rule.id, by: $0) },
                        canMove: { model.feed.canMove(id: rule.id, by: $0) },
                        duplicate: { model.feed.duplicate(rule.id) },
                        delete: { model.feed.delete(id: rule.id) }
                    ),
                    editor: { FeedRuleEditorView(model: model.feed, ruleID: rule.id) }
                )
            }
            .onMove { source, destination in
                model.feed.move(from: source, to: destination)
            }
            .onDelete { offsets in
                model.feed.delete(at: offsets)
            }
            Button {
                addedFeedRuleID = model.feed.add()
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .disabled(model.feed.isFull)
        } header: {
            FormSectionHeader {
                Text("Feed items")
            }
        } footer: {
            FormSectionFooter {
                Text(RulesView.feedListFooter)
                    .sectionFooter()
            }
        }
    }

    private func feedTitle(of rule: FeedRule) -> String? {
        rule.feedSubscriptionID.flatMap { model.feed.subscriptionTitle(for: $0) }
    }
}

/// What a rule's row draws, whichever list the rule is in.
private struct RuleRowItem {
    let name: String
    let enabled: Bool
    /// False for a rule this build can't render (#1901): no editor to push,
    /// no switch, no Duplicate.
    let isEditable: Bool
    let summary: String

    init(_ rule: Rule) {
        name = rule.name
        enabled = rule.enabled
        isEditable = rule.isEditable
        summary = RuleSummary.describe(rule)
    }

    init(_ rule: FeedRule, feedTitle: String?) {
        name = rule.name
        enabled = rule.enabled
        isEditable = rule.isEditable
        summary = FeedRuleSummary.describe(rule, feedTitle: feedTitle)
    }
}

/// What a rule's row can do to its rule, bound to the list the rule is in.
/// `move` and `canMove` take -1 for Move Up and +1 for Move Down.
private struct RuleRowActions {
    let setEnabled: (Bool) -> Void
    let move: (Int) -> Void
    let canMove: (Int) -> Bool
    let duplicate: () -> Void
    let delete: () -> Void
}

/// One rule's row, for a mail rule or a feed rule: the row takes what it
/// draws and does as values and builds the rule's editor from `editor`, so
/// the two lists share one row and its one platform split.
private struct RuleRow<Editor: View>: View {
    let item: RuleRowItem
    let actions: RuleRowActions
    @ViewBuilder let editor: () -> Editor

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
            if item.isEditable {
                NavigationLink {
                    editor()
                } label: {
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        // A rule this build can't render has no editor to push: the row
        // shows what it uses and stays read-only (#1901). Reorder and
        // delete still apply — neither rewrites the rule.
        Group {
            if item.isEditable {
                NavigationLink {
                    editor()
                } label: {
                    HStack(spacing: 12) {
                        enabledToggle
                        summary
                    }
                }
            } else {
                HStack(spacing: 12) {
                    enabledToggle
                    summary
                }
            }
        }
        .contextMenu {
            rowActions
        }
        #endif
    }

    private var enabledToggle: some View {
        // `RowSwitch`, not a bare `Toggle(...).labelsHidden()`: it carries
        // the Mac's mini switch style (the automatic toggle drew a checkbox
        // in the old list) and the label that keeps the control speaking as
        // a switch rather than a toggle button (#2040).
        RowSwitch(label: "Enabled", isOn: Binding(
            get: { item.enabled },
            set: { actions.setEnabled($0) }
        ))
        // Enabling is an edit like any other, and the model refuses one on
        // a rule it can't render, so the switch reads as broken unless it
        // is disabled with it.
        .disabled(!item.isEditable)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.name.isEmpty ? "Untitled rule" : item.name)
                    .foregroundStyle(item.enabled ? .primary : .secondary)
                if !item.isEditable {
                    Image(systemName: "lock")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Read-only")
                }
            }
            Text(item.summary)
                .appFont(.caption)
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
            actions.move(-1)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!actions.canMove(-1))
        Button {
            actions.move(1)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!actions.canMove(1))
        Divider()
        if item.isEditable {
            Button {
                actions.duplicate()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Button(role: .destructive) {
            actions.delete()
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
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// First-run screen, shown while both lists are empty: the plan's three
/// starter mail templates, the feed template, and a blank rule of either
/// kind. Templates arrive disabled with their destination (or sender, or
/// reply text, or word to look for) left for the user — a template never
/// names a folder that may not exist and never creates one.
private struct RulesEmptyState: View {
    @Bindable var model: RulesViewModel
    /// Set to the new rule's id so `RulesListView` pushes its editor.
    @Binding var addedRuleID: String?
    /// The same for a new feed rule.
    @Binding var addedFeedRuleID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No rules yet")
                    .appFont(.title3, weight: .semibold)
                Text(
                    "Rules file, flag, forward, or answer incoming mail for you, "
                    + "and flag or mark read new feed items. "
                    + "Start from a template or a blank rule."
                )
                    .appFont(.callout)
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
                    feedTemplateButton(
                        "Flag matching items",
                        subtitle: "Flag new feed items whose title has a word you pick",
                        template: RuleTemplates.flagMatchingItems()
                    )
                }
                Button("Start with a blank rule") {
                    addedRuleID = model.add()
                }
                .buttonStyle(.borderedProminent)
                Button("Start with a blank feed rule") {
                    addedFeedRuleID = model.feed.add()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private func templateButton(_ title: String, subtitle: String, template: Rule) -> some View {
        Button {
            addedRuleID = model.add(template)
        } label: {
            templateLabel(title, subtitle: subtitle)
        }
        .buttonStyle(.bordered)
    }

    private func feedTemplateButton(
        _ title: String, subtitle: String, template: FeedRule
    ) -> some View {
        Button {
            addedFeedRuleID = model.feed.add(template)
        } label: {
            templateLabel(title, subtitle: subtitle)
        }
        .buttonStyle(.bordered)
    }

    private func templateLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.body, weight: .medium)
            Text(subtitle).appFont(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
