import Foundation
import Observation
import CabalmailKit

/// Recyclable window identity for the compose scene group.
///
/// `WindowGroup(for:)` keys its presentation bookkeeping by the value it
/// was opened with and never retires a key, so a group keyed by the seed
/// `Draft` — which mints a fresh `UUID` per compose session — grows one
/// retained presentation per session for the life of the process
/// (issue #1084: ~9 MB apiece on iPad, ~8 MB on macOS, zero `deinit`s).
///
/// Keying the group by a small recycled index instead bounds that at the
/// number of composers ever open *at the same time*, which for a real
/// user is one or two. Side-by-side compose still works — a reply and a
/// forward take different slots — so the behaviour the group was chosen
/// for survives.
public struct ComposeSlot: Hashable, Codable, Sendable {
    let index: Int
}

/// Hands out compose window slots and remembers which seed each one is
/// currently showing.
///
/// The window value can no longer carry the seed (that is what made every
/// session a new key), so the seed travels here instead: `acquire` parks
/// it under the slot, the scene reads it back, and `release` frees the
/// index for the next composer without disturbing the seed — clearing it
/// on release would make the still-mounted window rebuild an empty
/// composer on its way out.
@Observable
@MainActor
public final class ComposeSlotRegistry {
    /// Seed per slot index. Entries outlive their session on purpose (see
    /// above); `acquire` overwrites the one it hands out.
    private var seeds: [Int: Draft] = [:]

    /// Indices currently backing an open composer.
    private var occupied: Set<Int> = []

    /// Sign-outs this process has seen; see `mayCompose(_:closedOn:)`.
    private(set) var session = 0

    init() {}

    /// Lowest free slot, parked with `seed`. Recycling the lowest index
    /// rather than appending is what keeps the common single-composer
    /// case pinned to slot 0 forever.
    public func acquire(seed: Draft) -> ComposeSlot {
        var index = 0
        while occupied.contains(index) { index += 1 }
        occupied.insert(index)
        seeds[index] = seed
        return ComposeSlot(index: index)
    }

    /// Replaces the seed of an already-open slot, should a `mailto:` link
    /// land in a window that has one. On macOS the system spawns a window
    /// for each link, which has no slot and keeps its seed itself (see
    /// `seed(forWindowWith:ownSeed:)`).
    func reseed(_ slot: ComposeSlot, with seed: Draft) {
        occupied.insert(slot.index)
        seeds[slot.index] = seed
    }

    /// The seed a slot should be composing from, or nil when the slot was
    /// never handed out in this process: a scene restored at launch with its
    /// value, on a platform that restores one (macOS does not).
    func seed(for slot: ComposeSlot) -> Draft? {
        seeds[slot.index]
    }

    /// What a compose window shows. A window opened with a slot composes
    /// from that slot's seed. A window without one composes from `ownSeed`,
    /// which it keeps for itself, and never from a slot's. Those are the
    /// windows this process did not open: a scene restored at launch (macOS
    /// brings it back with no value) or one the system spawned for a
    /// `mailto:` link.
    ///
    /// They used to fall back to slot 0. SwiftUI keeps a dismissed window
    /// mounted, so every such window the user had closed rebuilt and started
    /// a hidden composer whenever slot 0 was handed out again, and each one
    /// saved that draft to Drafts every minute until the app quit.
    func seed(forWindowWith slot: ComposeSlot?, ownSeed: Draft) -> Draft {
        guard let slot else { return ownSeed }
        return seed(for: slot) ?? Self.restoredSeed(for: slot)
    }

    /// Frees the index. The seed stays parked; the next `acquire` of this
    /// index replaces it, which is what resets the reused window.
    func release(_ slot: ComposeSlot) {
        occupied.remove(slot.index)
    }

    /// Number of composers currently holding a slot.
    var openCount: Int { occupied.count }

    // MARK: - Closed windows across a sign-out

    /// What a compose window's composer closed on.
    struct ClosedCompose: Equatable {
        let session: Int
        let seedID: UUID
    }

    func closedCompose(for seed: Draft) -> ClosedCompose {
        ClosedCompose(session: session, seedID: seed.id)
    }

    /// Called at sign-out, including the one an expired session forces.
    func endSession() {
        session += 1
    }

    /// Whether a compose window may build a composer for `seed`.
    ///
    /// SwiftUI keeps a closed window mounted and rebuilds its composer when
    /// the session comes back after a sign-out, including one forced by an
    /// expired session. Every closed window then started a hidden composer
    /// from the seed it closed on, saving it to Drafts every minute. A
    /// window that never closed always may. A closed one may in the session
    /// it closed in, so it keeps drawing its composer on its way out, and
    /// for a new seed, which is its slot being handed out again.
    func mayCompose(_ seed: Draft, closedOn closed: ClosedCompose?) -> Bool {
        guard let closed else { return true }
        return closed.session == session || closed.seedID != seed.id
    }

    /// Seed a restored scene composes from when this process never handed
    /// out its slot. Derived from the index rather than freshly minted so
    /// it is stable across body evaluations — an unstable seed identity
    /// would rebuild the composer on every redraw.
    static func restoredSeed(for slot: ComposeSlot) -> Draft {
        Draft(id: restoredSeedID(for: slot))
    }

    private static func restoredSeedID(for slot: ComposeSlot) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: Int64(slot.index).bigEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[8 + offset] = byte }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
