import Foundation
import CabalmailKit

/// One change to mail, posted on the mail store (`MailSessionStore.events`)
/// for every message list and reader to hear: a write a list, the reader or
/// the composer made through the mutation service (`MailMutationService`),
/// or a compose session's send or save.
///
/// A change names the messages it touched by ref, and each list matches it
/// against its own rows' refs: a folder list finds its folder's rows, and the
/// search surface, whose rows come from many folders, finds whichever of its
/// rows the change names (#1877). `origin` is the main window whose user
/// action it was (`commandWindowID`), or nil when no main window started it
/// (a compose window, or a list, which doesn't know its window); a list reads
/// it, and `advances`, to decide whether its selection moves
/// (`MailEventSelectionPolicy`, #1845). `sender` is the view model that made
/// the change, which has shown it on its own already and isn't sent it.
struct MailEvent: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// The messages are leaving their folders: a dispose, move or purge
        /// from a list or the reader, posted before the server answers, or a
        /// send from Drafts, which names every copy its compose session left
        /// there, since an autosave replaces the copy under a new UID and a
        /// list may be showing any of them (#1071). Lists drop the rows, and
        /// a selection on one of them moves on per the after-dispose
        /// preference.
        case removed([MessageRef])
        /// A removal posted as `.removed` failed on the server, so the message
        /// is back where it was. `markUnread` is set when the removal had
        /// marked an unread message read: the row comes back unread. Carried
        /// here rather than as a separate flag change so it can't reach a list
        /// before the row is back.
        case restored(MessageRef, markUnread: Bool)
        /// `flag` was added to, or removed from, each message.
        case flagsChanged([MessageRef], flag: Flag, added: Bool)
        /// A compose session changed what is in `folderPath` (Drafts). The
        /// retired UIDs are already expunged and the survivor carries what
        /// the user just saved, so a list showing the folder drops the one
        /// and re-points a reader at the other rather than advancing (#1078).
        /// A first save retires nothing and only adds: the survivor alone is
        /// news, because the refresh it prompts is what surfaces the new row
        /// rather than the 30 s status poll (#1083).
        case draftReplaced(folderPath: String, replacement: DraftReplacement)
        /// The reader marked the message read and asked to move on per
        /// `advance`. The row stays: only the selection moves, and a missing
        /// target means stay put. The `\Seen` change is its own
        /// `.flagsChanged`.
        case readAdvance(MessageRef, advance: MarkReadAdvance)
    }

    let change: Change
    /// The main window whose user action this is (`commandWindowID`), or nil
    /// for a change no main window started.
    let origin: UUID?
    /// The view model that made the change: a list that has already changed
    /// its own rows, counts and selection, or the reader, its own toolbar.
    /// `MailEvents` delivers the event to every subscriber but it. Nil for a
    /// change the composer made.
    let sender: ObjectIdentifier?
    /// Whether a list's selection on the event's rows may move on. False for
    /// a change a message list made: that list has seen to its own
    /// selection, and no other list's moves because of it, whatever window
    /// it is in.
    let advances: Bool

    init(change: Change, origin: UUID?, sender: ObjectIdentifier? = nil, advances: Bool = true) {
        self.change = change
        self.origin = origin
        self.sender = sender
        self.advances = advances
    }
}

extension MailEvent.Change {
    /// A change that says nothing: no message named, or a compose session
    /// that never reached the server (neither half of a draft replacement).
    /// `MailEvents.post` drops it.
    var isEmpty: Bool {
        switch self {
        case .removed(let refs), .flagsChanged(let refs, _, _):
            return refs.isEmpty
        case .draftReplaced(_, let replacement):
            return replacement.retiredUIDs.isEmpty && replacement.survivingUID == nil
        case .restored, .readAdvance:
            return false
        }
    }
}

/// Something that hears the mail store's events: a message list's view model
/// (`MessageListViewModel`), a reader's (`MessageDetailViewModel`), or a
/// test's recorder.
@MainActor
protocol MailEventSubscriber: AnyObject {
    func receive(_ event: MailEvent)
}

/// The mail store's events (`MailSessionStore.events`): every change posted
/// here reaches every subscriber in the order posted, synchronously, before
/// `post` returns, so a list has dropped an archived row by the time the
/// archive's server call goes out.
///
/// These replace the `last…` signal payloads the list used to observe with
/// `.onChange`. Those kept only their latest value, so two changes in one
/// update lost all but the last; they matched on the list's folder, so the
/// search surface, whose folder is a sentinel, ignored them (#1877); and they
/// named no window, so a reader action moved the selection in every window
/// (#1845). Nothing here is kept once delivered, so there is nothing to
/// replay and nothing for sign-out to reset.
///
/// Subscribers are held weakly and stay subscribed for their own lives. A
/// message list's view model subscribes when it is built rather than in its
/// view's `.task`: on iPhone the list under a pushed reader has had
/// `.onDisappear`, and it must still hear the archive the reader posts.
@MainActor
final class MailEvents {
    private struct WeakSubscriber {
        weak var subscriber: (any MailEventSubscriber)?
    }

    private var subscribers: [WeakSubscriber] = []
    /// Events posted while an earlier one is still being delivered (by a
    /// subscriber, from `receive`): delivered after it, so every subscriber
    /// hears every event in the same order.
    private var queued: [MailEvent] = []
    private var isDelivering = false

    init() {}

    /// Delivers every later event to `subscriber` until it goes away.
    /// Subscribing again changes nothing.
    func subscribe(_ subscriber: any MailEventSubscriber) {
        subscribers.removeAll { $0.subscriber == nil || $0.subscriber === subscriber }
        subscribers.append(WeakSubscriber(subscriber: subscriber))
    }

    /// Posts `change`, started in `origin` (the main window's
    /// `commandWindowID`, or nil), to every subscriber but `sender`, the view
    /// model that made it (see `MailEvent.sender` and `.advances`). An empty
    /// change (`MailEvent.Change.isEmpty`) is dropped.
    func post(
        _ change: MailEvent.Change,
        from origin: UUID?,
        sender: AnyObject? = nil,
        advances: Bool = true
    ) {
        guard !change.isEmpty else { return }
        queued.append(MailEvent(
            change: change, origin: origin, sender: sender.map(ObjectIdentifier.init), advances: advances
        ))
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !queued.isEmpty {
            let event = queued.removeFirst()
            subscribers.removeAll { $0.subscriber == nil }
            for subscriber in subscribers.compactMap(\.subscriber)
            where ObjectIdentifier(subscriber) != event.sender {
                subscriber.receive(event)
            }
        }
    }
}
