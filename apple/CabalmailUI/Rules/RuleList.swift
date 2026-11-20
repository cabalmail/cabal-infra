import Foundation
import CabalmailKit

/// What the rules list needs of a rule to edit a list of them: a mail rule
/// and a feed rule both have it, so one `RuleList` serves both.
protocol ListedRule: Equatable {
    var id: String { get set }
    var name: String { get set }
    var enabled: Bool { get set }
    /// False for a rule carrying a value this build doesn't know (#1901):
    /// it can be reordered and deleted, and nothing else.
    var isEditable: Bool { get }
}

extension Rule: ListedRule {}
extension FeedRule: ListedRule {}

/// One list of rules and the edits the Rules pane makes to it: add (up to
/// the server's cap), duplicate, delete, reorder, and write back an edited
/// rule. A value with no saving of its own: every mutation answers whether
/// it changed the list, and the owner schedules the save.
///
/// The mail list and the feed list are each one of these. The rules it
/// holds to are the same for both, so they live here once: a rule this
/// build can't render is never rewritten or copied, and an edit that
/// changes nothing is not a change.
struct RuleList<Element: ListedRule> {
    private(set) var rules: [Element] = []
    /// The server's cap on this list; `add` and `duplicate` stop at it.
    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = maxCount
    }

    var isFull: Bool { rules.count >= maxCount }

    /// Replaces the list whole: a load, or the server's canonical answer
    /// to a save.
    mutating func replace(with rules: [Element]) {
        self.rules = rules
    }

    func rule(withID id: String) -> Element? {
        rules.first { $0.id == id }
    }

    /// Writes an edited rule back. Refused for a rule that is gone, for one
    /// the editors render read-only (saving a rewritten copy of a rule this
    /// build can't represent would drop whatever its writer meant, #1901),
    /// and for an edit that changes nothing.
    mutating func update(_ rule: Element) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }),
              rules[index].isEditable,
              rules[index] != rule
        else { return false }
        rules[index] = rule
        return true
    }

    /// Appends `rule` and answers its id, or nil at the cap.
    mutating func add(_ rule: Element) -> String? {
        guard !isFull else { return nil }
        rules.append(rule)
        return rule.id
    }

    /// Inserts a copy of the rule after it, with a new id from `mintID` and
    /// " copy" on its name, and answers the copy's id. Nil at the cap, for
    /// a rule that is gone, and for one this build can't render: its copy
    /// would be a new rule this build can't express.
    mutating func duplicate(_ id: String, mintID: () -> String) -> String? {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              rules[index].isEditable,
              !isFull
        else { return nil }
        var copy = rules[index]
        copy.id = mintID()
        copy.name += " copy"
        rules.insert(copy, at: index + 1)
        return copy.id
    }

    mutating func delete(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    mutating func delete(id: String) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return false }
        rules.remove(at: index)
        return true
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves one rule `offset` places: -1 is Move Up and +1 Move Down.
    /// Past either end, or for a rule that is gone, nothing moves.
    mutating func move(id: String, by offset: Int) -> Bool {
        guard canMove(id: id, by: offset),
              let index = rules.firstIndex(where: { $0.id == id })
        else { return false }
        rules.insert(rules.remove(at: index), at: index + offset)
        return true
    }

    /// Whether `move(id:by:)` would move the rule, for the menus' enabling.
    func canMove(id: String, by offset: Int) -> Bool {
        guard offset != 0, let index = rules.firstIndex(where: { $0.id == id }) else { return false }
        return rules.indices.contains(index + offset)
    }

    mutating func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        guard var rule = rule(withID: id) else { return false }
        rule.enabled = enabled
        return update(rule)
    }
}
