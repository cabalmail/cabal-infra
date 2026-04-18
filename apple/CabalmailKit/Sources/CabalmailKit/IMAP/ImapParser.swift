import Foundation

/// Recursive-descent parser over the token stream produced by
/// `ImapTokenizer`. Consumes one response line per `parse(line:literals:)`
/// call and returns the corresponding `ImapResponse`.
enum ImapParser {
    static func parse(line: Data, literals: [Data]) -> ImapResponse {
        var tokenizer = ImapTokenizer(line: line, literals: literals)
        let first = tokenizer.next()

        switch first {
        case .atom(let value) where value == "*":
            return parseUntagged(&tokenizer)
        case .atom(let value) where value == "+":
            let text = remainingText(&tokenizer)
            return .continuation(text.trimmingCharacters(in: .whitespaces))
        case .atom(let tag):
            let next = tokenizer.next()
            guard case .atom(let statusRaw) = next,
                  let status = ImapStatus(rawValue: statusRaw.uppercased()) else {
                return .other(String(decoding: line, as: UTF8.self))
            }
            let text = remainingText(&tokenizer)
            return .completion(tag: tag, status: status, text: text.trimmingCharacters(in: .whitespaces))
        default:
            return .other(String(decoding: line, as: UTF8.self))
        }
    }

    // MARK: - Untagged

    private static func parseUntagged(_ tokenizer: inout ImapTokenizer) -> ImapResponse {
        let token = tokenizer.next()
        switch token {
        case .atom(let keyword):
            switch keyword.uppercased() {
            case "OK", "NO", "BAD", "BYE", "PREAUTH":
                let status = ImapStatus(rawValue: keyword.uppercased()) ?? .ok
                let text = remainingText(&tokenizer)
                return .status(code: status, text: text.trimmingCharacters(in: .whitespaces))
            case "CAPABILITY":
                var caps: [String] = []
                while case .atom(let cap) = tokenizer.next() {
                    caps.append(cap)
                }
                return .capability(caps)
            case "LIST":
                if let (attrs, delim, mailbox) = parseListLike(&tokenizer) {
                    return .list(attributes: attrs, delimiter: delim, mailbox: mailbox)
                }
                return .other("LIST")
            case "LSUB":
                if let (attrs, delim, mailbox) = parseListLike(&tokenizer) {
                    return .lsub(attributes: attrs, delimiter: delim, mailbox: mailbox)
                }
                return .other("LSUB")
            case "STATUS":
                return parseStatus(&tokenizer)
            case "SEARCH":
                var ids: [UInt32] = []
                while case .number(let n) = tokenizer.next() {
                    ids.append(UInt32(truncatingIfNeeded: n))
                }
                return .search(ids)
            case "FLAGS":
                // Reported after SELECT/EXAMINE — ignored for now.
                return .other("FLAGS")
            default:
                return .other(keyword)
            }
        case .number(let n):
            let n32 = UInt32(truncatingIfNeeded: n)
            if case .atom(let keyword) = tokenizer.next() {
                switch keyword.uppercased() {
                case "EXISTS":   return .exists(n32)
                case "EXPUNGE":  return .expunge(n32)
                case "RECENT":   return .recent(n32)
                case "FETCH":    return parseFetch(&tokenizer, sequence: n32)
                default:         return .other(keyword)
                }
            }
            return .other("untagged numeric \(n)")
        default:
            return .other("untagged")
        }
    }

    // MARK: - LIST / LSUB

    private static func parseListLike(_ tokenizer: inout ImapTokenizer) -> ([String], String, String)? {
        guard case .lparen = tokenizer.next() else { return nil }
        var attrs: [String] = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .rparen: return finishListLike(&tokenizer, attrs: attrs)
            case .atom(let a): attrs.append(a)
            case .quoted(let a): attrs.append(a)
            default: return nil
            }
        }
    }

    private static func finishListLike(_ tokenizer: inout ImapTokenizer, attrs: [String]) -> ([String], String, String)? {
        let delimToken = tokenizer.next()
        let delimiter: String
        switch delimToken {
        case .quoted(let s): delimiter = s
        case .nilValue:      delimiter = ""
        case .atom(let s):   delimiter = s
        default:             return nil
        }
        let mailboxToken = tokenizer.next()
        let mailbox: String
        switch mailboxToken {
        case .quoted(let s):    mailbox = s
        case .literal(let d):   mailbox = String(decoding: d, as: UTF8.self)
        case .atom(let s):      mailbox = s
        default:                return nil
        }
        return (attrs, delimiter, mailbox)
    }

    // MARK: - STATUS

    private static func parseStatus(_ tokenizer: inout ImapTokenizer) -> ImapResponse {
        let mboxToken = tokenizer.next()
        let mailbox: String
        switch mboxToken {
        case .quoted(let s):   mailbox = s
        case .atom(let s):     mailbox = s
        case .literal(let d):  mailbox = String(decoding: d, as: UTF8.self)
        default:               return .other("STATUS")
        }
        guard case .lparen = tokenizer.next() else { return .other("STATUS") }
        var attrs: [String: UInt64] = [:]
        while true {
            let key = tokenizer.next()
            if case .rparen = key { break }
            guard case .atom(let name) = key else { break }
            let value = tokenizer.next()
            if case .number(let n) = value {
                attrs[name.uppercased()] = n
            }
        }
        return .status2(mailbox: mailbox, attributes: attrs)
    }

    // MARK: - FETCH

    private static func parseFetch(_ tokenizer: inout ImapTokenizer, sequence: UInt32) -> ImapResponse {
        guard case .lparen = tokenizer.next() else { return .other("FETCH") }
        var attrs = ImapFetchAttributes()
        while true {
            let keyTok = tokenizer.next()
            if case .rparen = keyTok { break }
            guard case .atom(let key) = keyTok else { break }

            switch key.uppercased() {
            case "UID":
                if case .number(let n) = tokenizer.next() {
                    attrs.uid = UInt32(truncatingIfNeeded: n)
                }
            case "FLAGS":
                attrs.flags = readFlagList(&tokenizer)
            case "INTERNALDATE":
                if case .quoted(let s) = tokenizer.next() {
                    attrs.internalDate = parseInternalDate(s)
                }
            case "RFC822.SIZE":
                if case .number(let n) = tokenizer.next() {
                    attrs.rfc822Size = UInt32(truncatingIfNeeded: n)
                }
            case "ENVELOPE":
                attrs.envelope = parseEnvelope(&tokenizer)
            case "BODY", "BODY.PEEK", "RFC822":
                // BODY[...]<...> — skip section spec, then read the value.
                skipSectionSpec(&tokenizer)
                let token = tokenizer.next()
                switch token {
                case .literal(let data): attrs.body = data
                case .quoted(let s):     attrs.body = Data(s.utf8)
                case .nilValue:          break
                default:                 break
                }
            case "BODYSTRUCTURE":
                attrs.hasAttachments = readBodyStructureForAttachments(&tokenizer)
            default:
                // Unknown attribute — skip its value. Simplification: assume a
                // single-token scalar or one parenthesized group.
                skipOneValue(&tokenizer)
            }
        }
        return .fetch(sequence: sequence, attributes: attrs)
    }

    private static func readFlagList(_ tokenizer: inout ImapTokenizer) -> Set<Flag> {
        guard case .lparen = tokenizer.next() else { return [] }
        var flags: Set<Flag> = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .rparen: return flags
            case .atom(let a): flags.insert(Flag(wireValue: a))
            case .quoted(let a): flags.insert(Flag(wireValue: a))
            default: return flags
            }
        }
    }

    private static func parseEnvelope(_ tokenizer: inout ImapTokenizer) -> ImapEnvelopeFields {
        var env = ImapEnvelopeFields()
        guard case .lparen = tokenizer.next() else { return env }

        env.date = readNString(&tokenizer).flatMap(parseEnvelopeDate)
        env.subject = readNString(&tokenizer)
        env.from = readAddressList(&tokenizer)
        env.sender = readAddressList(&tokenizer)
        env.replyTo = readAddressList(&tokenizer)
        env.to = readAddressList(&tokenizer)
        env.cc = readAddressList(&tokenizer)
        env.bcc = readAddressList(&tokenizer)
        env.inReplyTo = readNString(&tokenizer)
        env.messageId = readNString(&tokenizer)

        // Consume closing paren of envelope (may have already been consumed if
        // the server returned fewer fields than expected).
        consumeClose(&tokenizer)
        return env
    }

    private static func readNString(_ tokenizer: inout ImapTokenizer) -> String? {
        let token = tokenizer.next()
        switch token {
        case .nilValue:        return nil
        case .quoted(let s):   return s
        case .literal(let d):  return String(decoding: d, as: UTF8.self)
        case .atom(let s):     return s
        default:               return nil
        }
    }

    private static func readAddressList(_ tokenizer: inout ImapTokenizer) -> [EmailAddress] {
        let token = tokenizer.next()
        switch token {
        case .nilValue: return []
        case .lparen: break
        default: return []
        }
        // Each address is `(name adl mailbox host)`.
        var addresses: [EmailAddress] = []
        while true {
            let t = tokenizer.peek()
            if case .rparen = t {
                _ = tokenizer.next()
                return addresses
            }
            _ = tokenizer.next() // consume lparen
            let name = readNString(&tokenizer)
            _ = readNString(&tokenizer) // source-route, effectively obsolete
            let mailbox = readNString(&tokenizer) ?? ""
            let host = readNString(&tokenizer) ?? ""
            consumeClose(&tokenizer)
            addresses.append(EmailAddress(name: name, mailbox: mailbox, host: host))
        }
    }

    private static func consumeClose(_ tokenizer: inout ImapTokenizer) {
        var depth = 0
        while true {
            let token = tokenizer.next()
            switch token {
            case .lparen: depth += 1
            case .rparen:
                if depth == 0 { return }
                depth -= 1
            case .endOfLine:
                return
            default:
                break
            }
        }
    }

    private static func skipOneValue(_ tokenizer: inout ImapTokenizer) {
        let token = tokenizer.next()
        switch token {
        case .lparen:
            var depth = 1
            while depth > 0 {
                let t = tokenizer.next()
                switch t {
                case .lparen: depth += 1
                case .rparen: depth -= 1
                case .endOfLine: return
                default: continue
                }
            }
        default:
            return
        }
    }

    private static func skipSectionSpec(_ tokenizer: inout ImapTokenizer) {
        // `BODY[...]<...>` — consume the optional section brackets. The
        // tokenizer treats `[` and `]` as their own tokens.
        if case .lbracket = tokenizer.peek() {
            _ = tokenizer.next()
            var depth = 1
            while depth > 0 {
                let t = tokenizer.next()
                switch t {
                case .lbracket: depth += 1
                case .rbracket: depth -= 1
                case .endOfLine: return
                default: continue
                }
            }
        }
    }

    // BODYSTRUCTURE heuristic: walk the structure and return true if any part
    // has a Content-Disposition of `attachment` or a non-text top-level type.
    // We don't fully model the tree — it's enough to scan for disposition
    // tokens, which are rare outside attachment parts.
    private static func readBodyStructureForAttachments(_ tokenizer: inout ImapTokenizer) -> Bool {
        guard case .lparen = tokenizer.next() else { return false }
        var depth = 1
        var foundAttachment = false
        while depth > 0 {
            let token = tokenizer.next()
            switch token {
            case .lparen: depth += 1
            case .rparen: depth -= 1
            case .endOfLine: return foundAttachment
            case .quoted(let s), .atom(let s):
                if s.lowercased() == "attachment" {
                    foundAttachment = true
                }
            default: continue
            }
        }
        return foundAttachment
    }

    // MARK: - Utility

    private static func remainingText(_ tokenizer: inout ImapTokenizer) -> String {
        var parts: [String] = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .endOfLine:        return parts.joined(separator: " ")
            case .atom(let s):      parts.append(s)
            case .quoted(let s):    parts.append(s)
            case .number(let n):    parts.append(String(n))
            case .nilValue:         parts.append("NIL")
            case .lparen:           parts.append("(")
            case .rparen:           parts.append(")")
            case .lbracket:         parts.append("[")
            case .rbracket:         parts.append("]")
            case .literal(let d):   parts.append(String(decoding: d, as: UTF8.self))
            }
        }
    }

    // MARK: - Dates

    /// Parses the envelope `date` string (per RFC 5322 `date-time`).
    private static func parseEnvelopeDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Parses an INTERNALDATE string: `dd-MMM-yyyy HH:mm:ss Z`.
    private static func parseInternalDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}
