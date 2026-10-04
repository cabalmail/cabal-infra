import Foundation
import CabalmailKit

// Script and record types `FakeImapClient` uses for the wire calls a reader
// open, a list refresh and list paging make. Each owns its own bookkeeping
// so the fake itself stays a thin dispatcher.

/// A FIFO of scripted results. Empty means "not scripted", so the caller
/// can fall back or trap.
struct ResultQueue<Value> {
    private var results: [Result<Value, Error>] = []

    mutating func append(_ more: [Result<Value, Error>]) {
        results.append(contentsOf: more)
    }

    mutating func next() -> Result<Value, Error>? {
        results.isEmpty ? nil : results.removeFirst()
    }
}

/// A folder's messages in server order. `envelopes(offset:limit:)` answers
/// by slicing it, the way the Lambda pages `/list_envelopes`, so a paging
/// test can request any window without scripting each page.
struct ScriptedFolderContents {
    let envelopes: [Envelope]

    func page(offset: UInt32, limit: UInt32) -> [Envelope] {
        let start = min(Int(offset), envelopes.count)
        let end = min(start + Int(limit), envelopes.count)
        return Array(envelopes[start..<end])
    }
}

/// The idle stream a test controls. Unscripted, `idle(folder:)` behaves like
/// the protocol default (a stream that finishes at once); once scripted,
/// each open hands back a stream the test can feed and end.
struct ScriptedIdleStreams {
    typealias Stream = AsyncThrowingStream<IdleEvent, Error>

    private(set) var isScripted = false
    private var continuations: [String: Stream.Continuation] = [:]

    mutating func script() {
        isScripted = true
    }

    /// Opens a stream for `folder`, replacing any earlier one for it.
    /// `onTermination` runs when the consumer stops listening.
    mutating func open(
        folder: String,
        onTermination: @escaping @Sendable () -> Void
    ) -> Stream {
        guard isScripted else { return Stream { $0.finish() } }
        let (stream, continuation) = Stream.makeStream()
        continuation.onTermination = { _ in onTermination() }
        continuations[folder] = continuation
        return stream
    }

    func emit(_ kind: IdleEvent.Kind, folder: String) {
        continuations[folder]?.yield(IdleEvent(kind: kind))
    }

    mutating func finish(folder: String, throwing error: Error?) {
        continuations.removeValue(forKey: folder)?.finish(throwing: error)
    }
}

/// One `fetchBody` key: the message a reader opened.
struct BodyKey: Hashable {
    let folder: String
    let uid: UInt32
}

extension FakeImapClient {
    /// A `status(path:flagged:)` request.
    public struct StatusCall: Sendable, Equatable {
        public let path: String
        public let flagged: Bool
    }

    /// A `topEnvelopes(folder:limit:totalMessages:sort:)` request.
    public struct TopEnvelopesCall: Sendable, Equatable {
        public let folder: String
        public let limit: UInt32
        public let totalMessages: UInt32
        public let sort: SortCriterion
    }

    /// An `envelopes(folder:offset:limit:sort:)` page request.
    public struct EnvelopesCall: Sendable, Equatable {
        public let folder: String
        public let offset: UInt32
        public let limit: UInt32
        public let sort: SortCriterion
    }

    /// A `fetchBody(folder:uid:)` request.
    public struct FetchBodyCall: Sendable, Equatable {
        public let folder: String
        public let uid: UInt32
    }
}
