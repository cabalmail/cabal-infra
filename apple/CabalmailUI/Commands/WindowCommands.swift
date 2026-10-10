import SwiftUI
import Observation
import CabalmailKit

/// A command a menu, or a button in a main window, asks that window's
/// surfaces to carry out. Each one has its own counter on the window's
/// `WindowCommands`, so two commands sent in one update never share a
/// target or a payload slot: a feed or sidebar-tree command names its
/// action in its case.
enum WindowCommand: Hashable {
    case reply, replyAll, forward
    case toggleSeen, toggleFlagged, moveSelection
    case refresh, markFolderRead, settings
    case feed(FeedCommand)
    case sidebarTree(SidebarTreeCommand)
}

/// Where a surface sits in its window: one of the tab layouts' tabs, or the
/// window itself (the wide layouts and macOS, which have no tab bar).
enum CommandSurface: Hashable {
    case window
    case tab(CompactTab)

    init(tab: CompactTab?) {
        self = tab.map(CommandSurface.tab) ?? .window
    }
}

/// Which surface is in front of a window, and whether a surface answers a
/// list or reader command. A tab layout keeps the tabs it has shown mounted,
/// so the Mail and Search tabs can each hold a list and a reader; only the
/// tab in front may answer, or have its availability read by the menus.
enum FrontSurfacePolicy {
    /// The tab bar's tab on the tab layouts; the window itself on the wide
    /// ones.
    static func front(layoutIsWide: Bool, compactTab: CompactTab) -> CommandSurface {
        layoutIsWide ? .window : .tab(compactTab)
    }

    /// A surface in no tab always answers: it is the only one of its kind in
    /// its window. A surface in a tab answers only while that tab is in front.
    static func answers(tab: CompactTab?, front: CommandSurface) -> Bool {
        guard let tab else { return true }
        return front == .tab(tab)
    }

    /// The section whose menu may hold the chords the Message and Feeds menus
    /// share (`SharedChordPolicy`). On the tab layouts the tab in front
    /// decides: Feeds is the feed reader's, and every other tab, Search
    /// included, is mail's. On the wide layouts the split reports it.
    static func activeSection(front: CommandSurface, reported: ResumeSession.Section) -> ResumeSession.Section {
        guard case .tab(let tab) = front else { return reported }
        return tab == .feeds ? .feeds : .mail
    }
}

/// One surface's report, and which reporter made it, so that a reporter
/// going away clears only its own report: a layout swap or a re-keyed view
/// brings the new reporter on before the old one leaves.
struct SurfaceReports<Value: Equatable>: Equatable {
    private struct Entry: Equatable {
        let reporter: UUID
        let value: Value
    }

    private var entries: [CommandSurface: Entry] = [:]

    func value(for surface: CommandSurface) -> Value? {
        entries[surface]?.value
    }

    mutating func set(_ value: Value, for surface: CommandSurface, by reporter: UUID) {
        entries[surface] = Entry(reporter: reporter, value: value)
    }

    mutating func clear(_ surface: CommandSurface, by reporter: UUID) {
        if entries[surface]?.reporter == reporter { entries[surface] = nil }
    }
}

/// One main window's menu commands: what its surfaces report the menus can
/// act on, and the commands the menus send it. `SignedInRootView` holds one
/// beside the window's `SceneNavigator`, puts it in the environment and
/// publishes it to the menus with `focusedSceneValue`, so a menu reads and
/// acts on the window in front and on no other. With no main window in front
/// (a compose or Settings window, or none open) the menus read nil and dim.
@Observable
@MainActor
public final class WindowCommands {
    /// The window's navigation, for which surface is in front.
    let navigator: SceneNavigator

    /// How many times each command has been sent. Surfaces watch their
    /// command's count (`answersCommand`).
    private(set) var counts: [WindowCommand: Int] = [:]

    /// What the Message menu can act on, per surface (`reportsMessageMenuAvailability`).
    private(set) var messageReports = SurfaceReports<MessageMenuAvailability>()
    /// What the Feeds menu's item commands can act on, per surface
    /// (`reportsFeedMenuAvailability`).
    private(set) var feedReports = SurfaceReports<FeedMenuAvailability>()
    /// The section the wide layouts' split reports (`reportsActiveSection`).
    var reportedSection: ResumeSession.Section = .mail
    /// What the macOS Mailbox menu can act on in this window.
    public internal(set) var mailbox = MailboxMenuAvailability()

    init(navigator: SceneNavigator) {
        self.navigator = navigator
    }

    // MARK: - Sending

    /// Sends `command` to this window's surfaces.
    func send(_ command: WindowCommand) {
        counts[command, default: 0] += 1
    }

    func count(of command: WindowCommand) -> Int {
        counts[command] ?? 0
    }

    // MARK: - The surface in front

    var front: CommandSurface {
        FrontSurfacePolicy.front(layoutIsWide: navigator.layoutIsWide, compactTab: navigator.compactTab)
    }

    /// Whether a surface in `tab` (nil: in no tab) answers list and reader
    /// commands now.
    func answers(in tab: CompactTab?) -> Bool {
        FrontSurfacePolicy.answers(tab: tab, front: front)
    }

    /// The section that may hold the shared chords (`SharedChordPolicy`).
    public var activeSection: ResumeSession.Section {
        FrontSurfacePolicy.activeSection(front: front, reported: reportedSection)
    }

    // MARK: - Availability

    /// What the Message menu acts on: the report of the surface in front.
    var messageMenu: MessageMenuAvailability {
        messageReports.value(for: front) ?? .none
    }

    /// What the Feeds menu's item commands act on: the surface in front's.
    var feedMenu: FeedMenuAvailability {
        feedReports.value(for: front) ?? .none
    }

    /// Which surface in `tab` holds ⌘⌫: none unless that surface is in front.
    func disposeChordHost(in tab: CompactTab?) -> DisposeChordHost {
        let surface = CommandSurface(tab: tab)
        guard surface == front else { return .none }
        return messageReports.value(for: surface)?.disposeChordHost ?? .none
    }

    func report(_ availability: MessageMenuAvailability, in tab: CompactTab?, by reporter: UUID) {
        messageReports.set(availability, for: CommandSurface(tab: tab), by: reporter)
    }

    func withdrawMessageReport(in tab: CompactTab?, by reporter: UUID) {
        messageReports.clear(CommandSurface(tab: tab), by: reporter)
    }

    func report(_ availability: FeedMenuAvailability, in tab: CompactTab?, by reporter: UUID) {
        feedReports.set(availability, for: CommandSurface(tab: tab), by: reporter)
    }

    func withdrawFeedReport(in tab: CompactTab?, by reporter: UUID) {
        feedReports.clear(CommandSurface(tab: tab), by: reporter)
    }
}

extension EnvironmentValues {
    /// The window's commands, for its surfaces to answer and report to. Nil
    /// outside a signed-in main window (previews, tests, the compose and
    /// Settings scenes).
    @Entry var windowCommands: WindowCommands?
    /// The tab a surface is in, set on each tab's content by the tab layouts;
    /// nil on the wide layouts. See `FrontSurfacePolicy`.
    @Entry var commandTab: CompactTab?
}

extension FocusedValues {
    /// The commands of the main window in front, read by the menus. Nil while
    /// a compose or Settings window is in front, or no main window is open.
    @Entry public var windowCommands: WindowCommands?
}

/// Runs an action when the window's commands send one of `commands`, if this
/// surface answers now.
private struct WindowCommandReceiver: ViewModifier {
    @Environment(\.windowCommands) private var windowCommands
    @Environment(\.commandTab) private var tab
    let commands: [WindowCommand]
    let whileBehind: Bool
    let action: (WindowCommand) -> Void

    /// The counts, with the object they came from: a window rebuilt for a
    /// new sign-in starts from zero, which is not a command.
    private struct Counts: Equatable {
        let owner: ObjectIdentifier?
        let values: [Int]
    }

    private var counts: Counts {
        Counts(
            owner: windowCommands.map(ObjectIdentifier.init),
            values: commands.map { windowCommands?.count(of: $0) ?? 0 }
        )
    }

    func body(content: Content) -> some View {
        content.onChange(of: counts) { old, new in
            guard old.owner == new.owner, let windowCommands,
                  whileBehind || windowCommands.answers(in: tab) else { return }
            for (index, command) in commands.enumerated() where new.values[index] > old.values[index] {
                action(command)
            }
        }
    }
}

extension View {
    /// Runs `action` each time this window's commands send `command`, while
    /// this surface is in front of its window (`FrontSurfacePolicy`).
    func answersCommand(_ command: WindowCommand, perform action: @escaping () -> Void) -> some View {
        modifier(WindowCommandReceiver(commands: [command], whileBehind: false) { _ in action() })
    }

    /// Runs `action` with whichever of `commands` this window sends. A
    /// surface that is its window's one handler for them (the feed catalog,
    /// a sidebar tree) passes `whileBehind` to answer from a tab not in front.
    func answersCommands(
        _ commands: [WindowCommand],
        whileBehind: Bool = false,
        perform action: @escaping (WindowCommand) -> Void
    ) -> some View {
        modifier(WindowCommandReceiver(commands: commands, whileBehind: whileBehind, action: action))
    }
}

/// The hidden button that carries ⌘⌫ for one surface. A key equivalent rides
/// a control rather than a menu item, so the chord acts on this window only,
/// and exactly one control in the window carries it at a time
/// (`DisposeChordHost`): two leave AppKit to pick a winner.
struct DisposeChordButton: View {
    @Environment(\.windowCommands) private var windowCommands
    @Environment(\.commandTab) private var tab
    let host: DisposeChordHost
    let action: () -> Void

    var body: some View {
        if windowCommands?.disposeChordHost(in: tab) == host {
            Button("", action: action)
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Tells the window's Mailbox menu which folder ⌥⌘T would act on while
    /// this list is on screen. The disappear is path-guarded because the list
    /// is re-keyed per folder and the new list appears before the old one goes.
    func reportsMailboxFolder(_ path: String) -> some View {
        modifier(MailboxFolderReporter(path: path))
    }
}

private struct MailboxFolderReporter: ViewModifier {
    @Environment(\.windowCommands) private var commands
    let path: String

    func body(content: Content) -> some View {
        content
            .onAppear { commands?.mailbox.folderListAppeared(path) }
            .onDisappear { commands?.mailbox.folderListDisappeared(path) }
    }
}
