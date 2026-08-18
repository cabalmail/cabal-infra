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
struct ComposeSlot: Hashable, Codable, Sendable {
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
final class ComposeSlotRegistry {
    /// Seed per slot index. Entries outlive their session on purpose (see
    /// above); `acquire` overwrites the one it hands out.
    private var seeds: [Int: Draft] = [:]

    /// Indices currently backing an open composer.
    private var occupied: Set<Int> = []

    init() {}

    /// Lowest free slot, parked with `seed`. Recycling the lowest index
    /// rather than appending is what keeps the common single-composer
    /// case pinned to slot 0 forever.
    func acquire(seed: Draft) -> ComposeSlot {
        var index = 0
        while occupied.contains(index) { index += 1 }
        occupied.insert(index)
        seeds[index] = seed
        return ComposeSlot(index: index)
    }

    /// Replaces the seed of an already-open slot. The `mailto:` handler
    /// needs this: the system spawns the window before the URL arrives,
    /// so the seed lands after the slot does.
    func reseed(_ slot: ComposeSlot, with seed: Draft) {
        occupied.insert(slot.index)
        seeds[slot.index] = seed
    }

    /// The seed a slot should be composing from, or nil when the slot was
    /// never handed out in this process — a scene the system restored at
    /// launch is the case that matters.
    func seed(for slot: ComposeSlot) -> Draft? {
        seeds[slot.index]
    }

    /// Frees the index. The seed stays parked; the next `acquire` of this
    /// index replaces it, which is what resets the reused window.
    func release(_ slot: ComposeSlot) {
        occupied.remove(slot.index)
    }

    /// Number of composers currently holding a slot.
    var openCount: Int { occupied.count }

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
