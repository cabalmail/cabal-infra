import Foundation
import Observation
import CabalmailKit

/// The one-way signals the reader and the composer send the message list:
/// a message disposed, a removal that failed on the server, a flag changed,
/// a mark-read that moves the selection on, and a Drafts copy replaced.
/// `MessageListView` observes each `last…` payload with `.onChange`; every
/// payload carries a monotonic `tick`, so the observer fires even when the
/// same logical payload (UID, flag, folder) recurs after a folder switch or
/// UIDVALIDITY reset.
///
/// Part of `MailSessionStore` (`signals`); it knows nothing of the other
/// parts. The signals and their ticks are not reset at sign-out. A flag
/// change or a failed removal also moves the folder's unread count, so those
/// two are sent through `MailSessionStore.signalFlagChange` and
/// `signalRemovalFailed`, which post them here (`postFlagChange`,
/// `postRemovalFailed`) and move the count; so is `markAnswered`, which
/// shields its STORE as well.
@Observable
@MainActor
final class MessageSignals {
    /// Latest envelope disposed from the detail view. `MessageListView`
    /// observes this via `.onChange` and prunes the matching UID from its
    /// in-memory list so the moved message disappears immediately, without
    /// waiting for the next refresh. `tick` is monotonic so
    /// re-disposing the same UID (e.g. in a different folder) still fires
    /// the observer.
    private(set) var lastDisposedEnvelope: DisposedEnvelope?
    private var disposedTick = 0

    /// Latest reader dispose / move / purge whose server write failed after
    /// `lastDisposedEnvelope` had already pruned the row. `MessageListView`
    /// puts the row back. Sent by `MailSessionStore.signalRemovalFailed`.
    private(set) var lastFailedRemoval: FailedRemoval?
    private(set) var failedRemovalTick = 0

    /// Latest envelope-flag change driven from the detail view (currently:
    /// `\Seen` toggles). `MessageListView` observes this so the row's bold
    /// styling and unread dot flip the moment the user taps "Mark as read"
    /// in the detail toolbar, without waiting for the next refresh. `tick`
    /// is monotonic so a revert (after a server error) still
    /// fires the observer when the same UID + flag flips back.
    private(set) var lastEnvelopeFlagChange: EnvelopeFlagChange?
    private var flagChangeTick = 0

    /// Latest mark-read-and-advance driven from the detail view's mark-read
    /// control. `MessageListView` observes this and moves the selection per
    /// the carried `MarkReadAdvance`; the `\Seen` flip itself travels on
    /// `lastEnvelopeFlagChange` as usual.
    private(set) var lastReadAdvanceRequest: ReadAdvanceRequest?
    private var readAdvanceTick = 0
    private(set) var lastDraftReplaced: DraftReplacedSignal?
    private var draftReplacedTick = 0

    init() {}

    func signalDisposed(_ ref: MessageRef) {
        signalDisposed([ref])
    }

    /// Multi-message form, for a sender that invalidates more than one row
    /// at once: a send-from-draft retires every Drafts copy its compose
    /// session created, not just the newest (#1071). The dispose's unread
    /// delta has already travelled on `signalFlagChange` from the reader's
    /// mark-read, so this moves no count.
    func signalDisposed(_ refs: [MessageRef]) {
        guard !refs.isEmpty else { return }
        disposedTick += 1
        lastDisposedEnvelope = DisposedEnvelope(refs: refs, tick: disposedTick)
    }

    /// A compose session changed what is in Drafts. The retired UIDs are
    /// already expunged server-side and the survivor carries the content the
    /// user just saved, so the list prunes the one and re-points at the
    /// other (#1078).
    ///
    /// A first save retires nothing and only adds: the survivor alone is
    /// enough to send, because the refresh the list runs on this signal is
    /// what surfaces the new row instead of leaving it to the 30 s status
    /// poll (#1083). A signal with neither half is the one that says
    /// nothing — an empty compose that never reached the server.
    func signalDraftReplaced(folderPath: String, replacement: DraftReplacement) {
        guard !replacement.retiredUIDs.isEmpty || replacement.survivingUID != nil else { return }
        draftReplacedTick += 1
        lastDraftReplaced = DraftReplacedSignal(
            folderPath: folderPath,
            replacement: replacement,
            tick: draftReplacedTick
        )
    }

    /// The payload half of `MailSessionStore.signalFlagChange`, which also
    /// moves the unread count; send a flag change through that.
    func postFlagChange(_ ref: MessageRef, flag: Flag, added: Bool) {
        flagChangeTick += 1
        lastEnvelopeFlagChange = EnvelopeFlagChange(
            ref: ref,
            flag: flag,
            added: added,
            tick: flagChangeTick
        )
    }

    func signalReadAdvance(_ ref: MessageRef, advance: MarkReadAdvance) {
        readAdvanceTick += 1
        lastReadAdvanceRequest = ReadAdvanceRequest(
            ref: ref,
            advance: advance,
            tick: readAdvanceTick
        )
    }

    /// The payload half of `MailSessionStore.signalRemovalFailed`, which also
    /// hands back the unread count; send a failed removal through that.
    func postRemovalFailed(_ ref: MessageRef, markUnread: Bool) {
        failedRemovalTick += 1
        lastFailedRemoval = FailedRemoval(ref: ref, markUnread: markUnread, tick: failedRemovalTick)
    }
}

/// Signal payload for a successful dispose action. Carries the disposed
/// messages' refs so list views showing other folders can ignore it, plus a
/// monotonic `tick` so `.onChange` fires even if the same message reappears
/// after a folder switch + UIDVALIDITY reset.
///
/// `refs` is usually one element — a disposed message is one row. A
/// send-from-draft names several: every copy its compose session left in
/// Drafts, since an autosave replaces the copy under a new UID and the list
/// may be rendering any of them (#1071). One signal rather than several
/// because `.onChange` observes the latest value, so back-to-back posts in
/// the same update would drop all but the last.
struct DisposedEnvelope: Equatable, Sendable {
    let refs: [MessageRef]
    let tick: Int
}

/// Signal payload for a reader dispose, move or purge that failed on the
/// server. The row was already pruned on the optimistic `DisposedEnvelope`;
/// this asks the list to put it back. `tick` is monotonic for the same
/// reason as `DisposedEnvelope`'s.
struct FailedRemoval: Equatable, Sendable {
    let ref: MessageRef
    /// The reader's dispose had marked an unread message read; the restored
    /// row comes back unread.
    let markUnread: Bool
    let tick: Int
}

/// Signal payload for a Drafts copy that `/save_draft` replaced in place —
/// posted when a compose session closes via Save Draft rather than Send.
/// Distinct from `DisposedEnvelope` because a replace is not a dispose:
/// something took the retired copy's place, so the list re-points at the
/// survivor instead of advancing to the next message per the user's
/// after-dispose preference (#1078).
struct DraftReplacedSignal: Equatable, Sendable {
    let folderPath: String
    let replacement: DraftReplacement
    let tick: Int
}

/// Signal payload for a flag change driven from outside the list (currently:
/// the detail view toggling `\Seen`). The list view applies this directly to
/// its in-memory envelope so the row updates without a server round trip.
/// `tick` is monotonic so toggling the same flag back and forth still fires
/// the observer.
struct EnvelopeFlagChange: Equatable, Sendable {
    let ref: MessageRef
    let flag: Flag
    let added: Bool
    let tick: Int
}

/// Signal payload for a mark-read that should also move the reading pane
/// (the detail toolbar's mark-read control, whose macOS option menu picks
/// where to go next). Distinct from `DisposedEnvelope` because the marked
/// row stays in the list — the observer only advances the selection, it
/// never prunes, and a missing advance target means "stay put" rather than
/// "clear the selection". `tick` is monotonic for the usual reason: marking
/// the same UID read again after an unread round trip must still fire.
struct ReadAdvanceRequest: Equatable, Sendable {
    let ref: MessageRef
    let advance: MarkReadAdvance
    let tick: Int
}
