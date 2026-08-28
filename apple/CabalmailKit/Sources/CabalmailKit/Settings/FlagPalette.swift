import Foundation

/// One entry in the user's custom-flag palette
/// (`docs/1.x/rules-composition-and-custom-flags-plan.md`, Phase 3).
///
/// `slot` is one of the fixed IMAP keyword atoms `cabal-flag-01` ...
/// `cabal-flag-20` (decision 4): the mailstore only ever sees slot atoms,
/// and everything user-visible — label, color, order, enabled — is palette
/// metadata riding synced preferences. Renaming a flag touches zero
/// messages; deleting and re-creating reuses the slot and never mints a
/// new keyword.
///
/// `color` stays a raw string rather than an enum on purpose: the server
/// enforces the fixed color set, and a color this build doesn't know (from
/// a newer client against a newer server) must round-trip unchanged
/// instead of being coerced and re-pushed. `FlagPalette.colors` is the set
/// the UI offers.
public struct FlagPaletteEntry: Codable, Hashable, Sendable, Identifiable {
    public var slot: String
    public var label: String
    public var color: String
    public var enabled: Bool

    public var id: String { slot }

    public init(slot: String, label: String, color: String, enabled: Bool = true) {
        self.slot = slot
        self.label = label
        self.color = color
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case slot, label, color, enabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(String.self, forKey: .slot)
        label = try container.decode(String.self, forKey: .label)
        color = try container.decode(String.self, forKey: .color)
        // The server treats a missing `enabled` as true; so do we.
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Wire marshalling and limits for the flag palette.
///
/// The palette rides the synced-preferences `app` map as a JSON-encoded
/// STRING under the `flag_palette` key — deliberately not a nested object,
/// because every shipped client decodes the app map as string-to-string
/// and a nested value would silently break their whole preferences pull.
/// The limits mirror `lambda/api/set_preferences/function.py`, the sole
/// enforcement point.
public enum FlagPalette {
    public static let maxEntries = 20
    public static let maxLabelLength = 32
    /// Every assignable slot atom, in order.
    public static let slots: [String] = (1...20).map { String(format: "cabal-flag-%02d", $0) }
    /// The fixed color vocabulary `set_preferences` accepts, in the order
    /// the pickers present it.
    public static let colors = [
        "red", "orange", "yellow", "green", "teal",
        "blue", "indigo", "purple", "pink", "gray",
    ]

    /// Decodes the wire string, or nil when it doesn't parse — callers keep
    /// their current palette rather than adopting garbage.
    public static func decode(_ wire: String) -> [FlagPaletteEntry]? {
        guard let data = wire.data(using: .utf8),
              let entries = try? JSONDecoder().decode([FlagPaletteEntry].self, from: data)
        else { return nil }
        return entries
    }

    /// Encodes for the wire in the server's canonical shape: compact,
    /// object keys sorted, array order preserved (array order IS the
    /// display order).
    public static func encode(_ entries: [FlagPaletteEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries),
              let wire = String(data: data, encoding: .utf8)
        else { return "[]" }
        return wire
    }

    /// The lowest slot atom not yet used, or nil at the 20-entry cap.
    public static func firstFreeSlot(in entries: [FlagPaletteEntry]) -> String? {
        let used = Set(entries.map(\.slot))
        return slots.first { !used.contains($0) }
    }
}
