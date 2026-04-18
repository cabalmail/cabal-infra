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
            return parseTagged(tag: tag, tokenizer: &tokenizer, line: line)
        default:
            return .other(decodeLine(line))
        }
    }

    private static func parseTagged(
        tag: String,
        tokenizer: inout ImapTokenizer,
        line: Data
    ) -> ImapResponse {
        let next = tokenizer.next()
        guard case .atom(let statusRaw) = next,
              let status = ImapStatus(rawValue: statusRaw.uppercased()) else {
            return .other(decodeLine(line))
        }
        let text = remainingText(&tokenizer)
        return .completion(tag: tag, status: status, text: text.trimmingCharacters(in: .whitespaces))
    }

    fileprivate static func decodeLine(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Untagged dispatch

extension ImapParser {
    static func parseUntagged(_ tokenizer: inout ImapTokenizer) -> ImapResponse {
        let token = tokenizer.next()
        switch token {
        case .atom(let keyword):
            return dispatchKeyword(keyword.uppercased(), tokenizer: &tokenizer, originalKeyword: keyword)
        case .number(let number):
            return dispatchNumeric(number: number, tokenizer: &tokenizer)
        default:
            return .other("untagged")
        }
    }

    static func dispatchKeyword(
        _ upper: String,
        tokenizer: inout ImapTokenizer,
        originalKeyword: String
    ) -> ImapResponse {
        switch upper {
        case "OK", "NO", "BAD", "BYE", "PREAUTH":
            let status = ImapStatus(rawValue: upper) ?? .ok
            let text = remainingText(&tokenizer)
            return .status(code: status, text: text.trimmingCharacters(in: .whitespaces))
        case "CAPABILITY":
            return .capability(readCapabilities(&tokenizer))
        case "LIST":
            guard let fields = parseListLike(&tokenizer) else { return .other("LIST") }
            return .list(attributes: fields.attributes, delimiter: fields.delimiter, mailbox: fields.mailbox)
        case "LSUB":
            guard let fields = parseListLike(&tokenizer) else { return .other("LSUB") }
            return .lsub(attributes: fields.attributes, delimiter: fields.delimiter, mailbox: fields.mailbox)
        case "STATUS":
            return parseStatus(&tokenizer)
        case "SEARCH":
            return .search(readSearchIDs(&tokenizer))
        case "FLAGS":
            // FLAGS is reported after SELECT/EXAMINE — not consumed by Phase 3.
            return .other("FLAGS")
        default:
            return .other(originalKeyword)
        }
    }

    static func dispatchNumeric(number: UInt64, tokenizer: inout ImapTokenizer) -> ImapResponse {
        let sequence = UInt32(truncatingIfNeeded: number)
        guard case .atom(let keyword) = tokenizer.next() else {
            return .other("untagged numeric \(number)")
        }
        switch keyword.uppercased() {
        case "EXISTS":  return .exists(sequence)
        case "EXPUNGE": return .expunge(sequence)
        case "RECENT":  return .recent(sequence)
        case "FETCH":   return parseFetch(&tokenizer, sequence: sequence)
        default:        return .other(keyword)
        }
    }

    static func readCapabilities(_ tokenizer: inout ImapTokenizer) -> [String] {
        var caps: [String] = []
        while case .atom(let cap) = tokenizer.next() {
            caps.append(cap)
        }
        return caps
    }

    static func readSearchIDs(_ tokenizer: inout ImapTokenizer) -> [UInt32] {
        var ids: [UInt32] = []
        while case .number(let number) = tokenizer.next() {
            ids.append(UInt32(truncatingIfNeeded: number))
        }
        return ids
    }
}

// MARK: - LIST / LSUB

extension ImapParser {
    struct ListLikeFields {
        let attributes: [String]
        let delimiter: String
        let mailbox: String
    }

    static func parseListLike(_ tokenizer: inout ImapTokenizer) -> ListLikeFields? {
        guard case .lparen = tokenizer.next() else { return nil }
        var attrs: [String] = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .rparen:
                return finishListLike(&tokenizer, attrs: attrs)
            case .atom(let attr):
                attrs.append(attr)
            case .quoted(let attr):
                attrs.append(attr)
            default:
                return nil
            }
        }
    }

    static func finishListLike(
        _ tokenizer: inout ImapTokenizer,
        attrs: [String]
    ) -> ListLikeFields? {
        guard let delimiter = readDelimiter(&tokenizer) else { return nil }
        guard let mailbox = readMailboxName(&tokenizer) else { return nil }
        return ListLikeFields(attributes: attrs, delimiter: delimiter, mailbox: mailbox)
    }

    static func readDelimiter(_ tokenizer: inout ImapTokenizer) -> String? {
        switch tokenizer.next() {
        case .quoted(let value): return value
        case .nilValue:          return ""
        case .atom(let value):   return value
        default:                 return nil
        }
    }

    static func readMailboxName(_ tokenizer: inout ImapTokenizer) -> String? {
        switch tokenizer.next() {
        case .quoted(let value):  return value
        case .literal(let data):  return String(bytes: data, encoding: .utf8) ?? ""
        case .atom(let value):    return value
        default:                  return nil
        }
    }
}

// MARK: - STATUS

extension ImapParser {
    static func parseStatus(_ tokenizer: inout ImapTokenizer) -> ImapResponse {
        let mboxToken = tokenizer.next()
        let mailbox: String
        switch mboxToken {
        case .quoted(let value):   mailbox = value
        case .atom(let value):     mailbox = value
        case .literal(let data):   mailbox = String(bytes: data, encoding: .utf8) ?? ""
        default:                   return .other("STATUS")
        }
        guard case .lparen = tokenizer.next() else { return .other("STATUS") }
        var attrs: [String: UInt64] = [:]
        while true {
            let key = tokenizer.next()
            if case .rparen = key { break }
            guard case .atom(let name) = key else { break }
            let value = tokenizer.next()
            if case .number(let number) = value {
                attrs[name.uppercased()] = number
            }
        }
        return .status2(mailbox: mailbox, attributes: attrs)
    }
}

// MARK: - FETCH

extension ImapParser {
    static func parseFetch(_ tokenizer: inout ImapTokenizer, sequence: UInt32) -> ImapResponse {
        guard case .lparen = tokenizer.next() else { return .other("FETCH") }
        var attrs = ImapFetchAttributes()
        while true {
            let keyTok = tokenizer.next()
            if case .rparen = keyTok { break }
            guard case .atom(let key) = keyTok else { break }
            applyFetchAttribute(key: key, tokenizer: &tokenizer, into: &attrs)
        }
        return .fetch(sequence: sequence, attributes: attrs)
    }

    static func applyFetchAttribute(
        key: String,
        tokenizer: inout ImapTokenizer,
        into attrs: inout ImapFetchAttributes
    ) {
        switch key.uppercased() {
        case "UID":           attrs.uid = readUInt32(&tokenizer)
        case "FLAGS":         attrs.flags = readFlagList(&tokenizer)
        case "INTERNALDATE":  attrs.internalDate = readQuoted(&tokenizer).flatMap(parseInternalDate)
        case "RFC822.SIZE":   attrs.rfc822Size = readUInt32(&tokenizer)
        case "ENVELOPE":      attrs.envelope = parseEnvelope(&tokenizer)
        case "BODY", "BODY.PEEK", "RFC822":
            skipSectionSpec(&tokenizer)
            readBodyValue(&tokenizer, into: &attrs)
        case "BODYSTRUCTURE": attrs.hasAttachments = readBodyStructureForAttachments(&tokenizer)
        default:
            // Unknown attribute — skip its value. Simplification: assume a
            // single-token scalar or one parenthesized group.
            skipOneValue(&tokenizer)
        }
    }

    static func readUInt32(_ tokenizer: inout ImapTokenizer) -> UInt32? {
        if case .number(let number) = tokenizer.next() {
            return UInt32(truncatingIfNeeded: number)
        }
        return nil
    }

    static func readQuoted(_ tokenizer: inout ImapTokenizer) -> String? {
        if case .quoted(let value) = tokenizer.next() {
            return value
        }
        return nil
    }

    static func readBodyValue(_ tokenizer: inout ImapTokenizer, into attrs: inout ImapFetchAttributes) {
        switch tokenizer.next() {
        case .literal(let data):  attrs.body = data
        case .quoted(let value):  attrs.body = Data(value.utf8)
        case .nilValue:           break
        default:                  break
        }
    }

    static func readFlagList(_ tokenizer: inout ImapTokenizer) -> Set<Flag> {
        guard case .lparen = tokenizer.next() else { return [] }
        var flags: Set<Flag> = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .rparen:           return flags
            case .atom(let name):   flags.insert(Flag(wireValue: name))
            case .quoted(let name): flags.insert(Flag(wireValue: name))
            default:                return flags
            }
        }
    }
}
