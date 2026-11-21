import SwiftUI
import CabalmailKit

/// Detail form for one feed rule: name, the feed it applies to, the ANDed
/// text conditions, and the marks it makes (flags and Mark as read). Every
/// control writes through `FeedRulesEditor.update`, which has
/// `RulesViewModel` schedule the debounced whole-set save.
///
/// A feed rule is a mail rule with the filing taken out, so this is the mail
/// editor without Continue, Destination, Forward and Reply. Nothing is
/// filed, which is also why there is no order to explain: every enabled rule
/// that matches a new item applies to it.
struct FeedRuleEditorView: View {
    @Bindable var model: FeedRulesEditor
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
            FeedRuleScopeSection(rule: rule, subscriptions: model.subscriptions)
            FeedRuleConditionsSection(rule: rule)
            FeedRuleActionsSection(rule: rule)
        }
        .groupedFormStyleOnMac()
        .navigationTitle(model.rule(withID: ruleID)?.name ?? "Rule")
        .inlineNavigationTitle()
    }

    /// Write-through binding into the model; the getter's fallback only
    /// exists for the frame where the rule disappears mid-render.
    private var rule: Binding<FeedRule> {
        Binding(
            get: { model.rule(withID: ruleID) ?? FeedRule(id: ruleID) },
            set: { model.update($0) }
        )
    }
}

/// The feed the rule is limited to. On the wire this is a condition (`feed`,
/// holding a subscription id), but it is not a "contains" test: the server
/// matches it exactly and allows one to a rule. So the editor shows it as
/// the rule's scope, a picker of its own, and the model keeps it to one
/// condition (`FeedRule.feedSubscriptionID`).
private struct FeedRuleScopeSection: View {
    @Binding var rule: FeedRule
    let subscriptions: [RssSubscription]

    var body: some View {
        Section {
            Picker("Feed", selection: selection) {
                Text("All feeds").tag("")
                // A stored feed this device doesn't list stays selectable
                // (and is explained in the footer) instead of silently
                // resetting to All feeds, which would widen the rule.
                if let stored = rule.feedSubscriptionID, !isListed(stored) {
                    Text(subscriptions.isEmpty ? "One feed" : "Unsubscribed feed").tag(stored)
                }
                ForEach(subscriptions) { subscription in
                    Text(subscription.displayTitle).tag(subscription.subscriptionId)
                }
            }
        } footer: {
            FormSectionFooter {
                Text(FeedRuleEditorText.scopeFooter(for: rule, subscriptions: subscriptions))
                    .sectionFooter()
            }
        }
    }

    /// "" stands for All feeds: a picker needs a tag for it, and no
    /// subscription id is empty.
    private var selection: Binding<String> {
        Binding(
            get: { rule.feedSubscriptionID ?? "" },
            set: { rule.feedSubscriptionID = $0.isEmpty ? nil : $0 }
        )
    }

    private func isListed(_ id: String) -> Bool {
        subscriptions.contains { $0.subscriptionId == id }
    }
}

/// The ANDed text conditions: field picker + contains-value text field. The
/// rule's `feed` condition is in the same array on the wire and is skipped
/// here; `FeedRuleScopeSection` owns it.
private struct FeedRuleConditionsSection: View {
    @Binding var rule: FeedRule

    var body: some View {
        Section {
            ForEach($rule.conditions) { $condition in
                if condition.field != .feed {
                    HStack {
                        Picker("Field", selection: $condition.field) {
                            ForEach(FeedRule.Field.textCases, id: \.self) { field in
                                Text(FeedRuleSummary.fieldName(field)).tag(field)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 120, alignment: .leading)
                        TextField("contains…", text: $condition.value)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textEntry(.verbatim)
                        Button(role: .destructive) {
                            rule.conditions.removeAll { $0.id == condition.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(ColorTokens.dangerFg)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove condition")
                    }
                }
            }
            Button {
                rule.conditions.append(FeedRule.Condition())
            } label: {
                Label("Add condition", systemImage: "plus.circle")
            }
            // The server's cap counts the feed condition too.
            .disabled(rule.conditions.count >= RulesValidator.maxConditions)
        } header: {
            FormSectionHeader {
                Text("Conditions")
            }
        } footer: {
            FormSectionFooter {
                Text(FeedRuleEditorText.conditionsFooter(for: rule))
                    .sectionFooter()
            }
        }
    }
}

/// The marks a feed rule makes: the flags, as the mail editor lists them,
/// and Mark as read. They are all a feed rule can do.
private struct FeedRuleActionsSection: View {
    @Binding var rule: FeedRule
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Section {
            RuleFlagToggles(flag: $rule.flag, flags: $rule.flags)
            Toggle("Mark as read", isOn: $rule.markRead)
        } header: {
            FormSectionHeader {
                Text("Actions")
            }
        } footer: {
            FormSectionFooter {
                Text(FeedRuleEditorText.actionsFooter(
                    for: rule,
                    hasDeletedFlag: !RuleFlagToggles.straySlots(
                        palette: FlagPalette.effective(preferences.flagPalette), flags: rule.flags
                    ).isEmpty
                ))
                .sectionFooter()
            }
        }
    }
}

/// The feed rule editor's section footers, as plain functions of the rule so
/// what each says in each state can be tested without drawing the form.
enum FeedRuleEditorText {
    static func scopeFooter(for rule: FeedRule, subscriptions: [RssSubscription]) -> String {
        guard let stored = rule.feedSubscriptionID else {
            return "This rule looks at new items in every feed you subscribe to."
        }
        // An empty list usually means the feeds haven't loaded on this
        // device; don't call every stored feed unsubscribed in that case.
        if subscriptions.isEmpty || subscriptions.contains(where: { $0.subscriptionId == stored }) {
            return "This rule looks at new items in this feed only."
        }
        return "You no longer subscribe to that feed, so this rule matches nothing "
            + "until you pick another feed or All feeds."
    }

    static func conditionsFooter(for rule: FeedRule) -> String {
        if rule.conditions.contains(where: { $0.field != .feed }) {
            return "All conditions must match (case-insensitive contains). "
                + "Summary also searches the item's text."
        }
        return rule.feedSubscriptionID == nil
            ? "No conditions: this rule matches every new item in every feed."
            : "No conditions: this rule matches every new item in this feed."
    }

    static func actionsFooter(for rule: FeedRule, hasDeletedFlag: Bool) -> String {
        if hasDeletedFlag {
            return "This rule sets a flag that was deleted, so it is skipped. "
                + "Switch that flag off here to bring the rule back."
        }
        if !rule.hasAction {
            return "This rule does nothing yet: switch on a flag or Mark as read."
        }
        return "Applied once, when a new item is fetched. Mark as read never overrules "
            + "a mark you made yourself."
    }
}
