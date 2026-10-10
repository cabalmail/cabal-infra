import Foundation
import CabalmailKit

/// Where a folder list is scrolled: the row at its top, by identity
/// (Message-ID, then UID) and by absolute position in the folder's sorted
/// order. The top of a list is no anchor: a list opens there anyway.
struct ListAnchor: Codable, Hashable, Sendable {
    let folderPath: String
    let messageID: String?
    let uid: UInt32?
    /// The row's absolute index in the folder (`MessageListSlot.index`).
    let index: Int

    /// Nil for an index of 0 or less: the top stores nothing.
    init?(folderPath: String, messageID: String?, uid: UInt32?, index: Int) {
        guard index > 0 else { return nil }
        self.folderPath = folderPath
        self.messageID = messageID.flatMap { $0.isEmpty ? nil : $0 }
        self.uid = uid
        self.index = index
    }

    /// The same message at another row: what a list records while its
    /// landing waits for the message's row (a guess never overwrites the
    /// identity), and where a landing found it.
    func moved(to index: Int) -> ListAnchor? {
        ListAnchor(folderPath: folderPath, messageID: messageID, uid: uid, index: index)
    }

    /// Whether `envelope` is the message this anchor names: by Message-ID
    /// when both have one, else by UID.
    func names(_ envelope: Envelope) -> Bool {
        if let messageID, let other = envelope.messageId, !other.isEmpty { return messageID == other }
        return uid == envelope.uid
    }
}

extension ListAnchor {
    /// What a list does with this anchor once it has appeared and loaded.
    enum Landing: Equatable {
        /// The message is loaded at `row`: scroll there.
        case found(row: Int)
        /// The message isn't among the loaded rows, which reach well past
        /// the anchor's position on both sides: scroll to that position.
        case position(row: Int)
        /// The rows around the anchor's position aren't loaded: load around
        /// it, scroll there, and correct once the message's row arrives.
        case guess(row: Int)
        /// The anchor is past the loaded rows and the folder's count hasn't
        /// arrived (offline): don't scroll, keep the anchor.
        case wait
        /// The folder has no rows.
        case drop
    }

    /// How far the loaded rows must reach past the anchor's position, on
    /// both sides, before a message missing from them counts as gone rather
    /// than shifted out of the window by mail that arrived since.
    static let settledMargin = 50

    /// - Parameters:
    ///   - rows: the loaded window, starting at absolute `windowStart`.
    ///   - slotCount: the list's length (`MessageListViewModel.slotCount`).
    ///   - countKnown: whether a STATUS has given the folder's count.
    func landing(rows: [Envelope], windowStart: Int, slotCount: Int, countKnown: Bool) -> Landing {
        if let row = row(in: rows, windowStart: windowStart) { return .found(row: row) }
        if slotCount == 0 { return countKnown ? .drop : .wait }
        if index >= slotCount, !countKnown { return .wait }
        let target = min(index, slotCount - 1)
        let lower = max(0, target - Self.settledMargin)
        let upper = min(slotCount - 1, target + Self.settledMargin)
        let loaded = windowStart..<(windowStart + rows.count)
        return loaded.contains(lower) && loaded.contains(upper) ? .position(row: target) : .guess(row: target)
    }

    /// The absolute row of this anchor's message among `rows`: by
    /// Message-ID, nearest `index` when two rows carry it (the lower on a
    /// tie), else by UID.
    func row(in rows: [Envelope], windowStart: Int) -> Int? {
        if let messageID {
            let matches = rows.indices.filter { rows[$0].messageId == messageID }.map { windowStart + $0 }
            if let nearest = matches.min(by: { abs($0 - index) < abs($1 - index) }) { return nearest }
        }
        if let uid, let local = rows.firstIndex(where: { $0.uid == uid }) { return windowStart + local }
        return nil
    }
}

extension ResumeSession {
    /// The list place this record keeps for its folder, in its four plain
    /// fields. One left behind for another folder reads as none.
    var listAnchor: ListAnchor? {
        get {
            guard let path = listAnchorFolder, path == folder, let index = listAnchorIndex else { return nil }
            return ListAnchor(folderPath: path, messageID: listAnchorMessageID, uid: listAnchorUID, index: index)
        }
        set {
            listAnchorFolder = newValue?.folderPath
            listAnchorMessageID = newValue?.messageID
            listAnchorUID = newValue?.uid
            listAnchorIndex = newValue?.index
        }
    }
}
