import Foundation

/// Extracts RFC 5322 message-ids from header values.
///
/// `Message-ID`, `In-Reply-To`, and `References` all carry one or more
/// angle-bracketed `<id-left@id-right>` tokens, possibly with comments or
/// folding whitespace between them. This is the client-side mirror of the
/// Lambda's `parse_message_ids` (`lambda/api/_shared/helper.py`), so both
/// ends agree on what counts as an id.
public enum MessageIds {
    /// Returns every angle-bracketed token in `raw`, brackets included
    /// (matching the wire shape the Lambda emits). Nil or token-free input
    /// yields an empty list.
    public static func parse(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var ids: [String] = []
        var current: String?
        for character in raw {
            switch character {
            case "<":
                current = "<"
            case ">":
                if var token = current, token.count > 1 {
                    token.append(">")
                    ids.append(token)
                }
                current = nil
            default:
                current?.append(character)
            }
        }
        return ids
    }
}
