import Foundation

// Extensions continuing `ImapParser` — split across files so the primary
// parse-dispatch file stays under the file-length lint limit.

// MARK: - Envelope / address lists

extension ImapParser {
    static func parseEnvelope(_ tokenizer: inout ImapTokenizer) -> ImapEnvelopeFields {
        var env = ImapEnvelopeFields()
        guard case .lparen = tokenizer.next() else { return env }

        env.date = readNString(&tokenizer).flatMap(parseEnvelopeDate)
        // Subject (and address display names below) arrive as raw RFC 2047
        // headers per RFC 3501 — decode encoded-words so non-ASCII renders.
        env.subject = readNString(&tokenizer).map(HeaderDecoder.decode)
        env.from = readAddressList(&tokenizer)
        env.sender = readAddressList(&tokenizer)
        env.replyTo = readAddressList(&tokenizer)
        env.to = readAddressList(&tokenizer)
        env.cc = readAddressList(&tokenizer)
        env.bcc = readAddressList(&tokenizer)
        env.inReplyTo = readNString(&tokenizer)
        env.messageId = readNString(&tokenizer)

        // Consume the closing paren of envelope (may have already been consumed
        // if the server returned fewer fields than expected).
        consumeClose(&tokenizer)
        return env
    }

    static func readNString(_ tokenizer: inout ImapTokenizer) -> String? {
        let token = tokenizer.next()
        switch token {
        case .nilValue:          return nil
        case .quoted(let value): return value
        case .literal(let data): return String(bytes: data, encoding: .utf8) ?? ""
        case .atom(let value):   return value
        default:                 return nil
        }
    }

    static func readAddressList(_ tokenizer: inout ImapTokenizer) -> [EmailAddress] {
        let token = tokenizer.next()
        switch token {
        case .nilValue: return []
        case .lparen:   break
        default:        return []
        }
        // Each address is `(name adl mailbox host)`.
        var addresses: [EmailAddress] = []
        while true {
            let peeked = tokenizer.peek()
            if case .rparen = peeked {
                _ = tokenizer.next()
                return addresses
            }
            _ = tokenizer.next() // consume lparen
            let name = readNString(&tokenizer).map(HeaderDecoder.decode)
            _ = readNString(&tokenizer) // source-route, effectively obsolete
            let mailbox = readNString(&tokenizer) ?? ""
            let host = readNString(&tokenizer) ?? ""
            consumeClose(&tokenizer)
            addresses.append(EmailAddress(name: name, mailbox: mailbox, host: host))
        }
    }
}

// MARK: - Skip / structure helpers

extension ImapParser {
    static func consumeClose(_ tokenizer: inout ImapTokenizer) {
        var depth = 0
        while true {
            let token = tokenizer.next()
            switch token {
            case .lparen:
                depth += 1
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

    static func skipOneValue(_ tokenizer: inout ImapTokenizer) {
        let token = tokenizer.next()
        if case .lparen = token {
            var depth = 1
            while depth > 0 {
                switch tokenizer.next() {
                case .lparen:     depth += 1
                case .rparen:     depth -= 1
                case .endOfLine:  return
                default:          continue
                }
            }
        }
    }

    static func skipSectionSpec(_ tokenizer: inout ImapTokenizer) {
        // `BODY[...]<...>` — consume the optional section brackets. The
        // tokenizer treats `[` and `]` as their own tokens.
        guard case .lbracket = tokenizer.peek() else { return }
        _ = tokenizer.next()
        var depth = 1
        while depth > 0 {
            switch tokenizer.next() {
            case .lbracket:   depth += 1
            case .rbracket:   depth -= 1
            case .endOfLine:  return
            default:          continue
            }
        }
    }

    // BODYSTRUCTURE heuristic: walk the structure and return true if any part
    // has a Content-Disposition of `attachment` or a non-text top-level type.
    // We don't fully model the tree — it's enough to scan for disposition
    // tokens, which are rare outside attachment parts.
    static func readBodyStructureForAttachments(_ tokenizer: inout ImapTokenizer) -> Bool {
        guard case .lparen = tokenizer.next() else { return false }
        var depth = 1
        var foundAttachment = false
        while depth > 0 {
            let token = tokenizer.next()
            switch token {
            case .lparen:
                depth += 1
            case .rparen:
                depth -= 1
            case .endOfLine:
                return foundAttachment
            case .quoted(let value), .atom(let value):
                if value.lowercased() == "attachment" {
                    foundAttachment = true
                }
            default:
                continue
            }
        }
        return foundAttachment
    }
}

// MARK: - Text / dates

extension ImapParser {
    static func remainingText(_ tokenizer: inout ImapTokenizer) -> String {
        var parts: [String] = []
        while true {
            let token = tokenizer.next()
            if case .endOfLine = token { return parts.joined(separator: " ") }
            parts.append(renderToken(token))
        }
    }

    static func renderToken(_ token: ImapTokenizer.Token) -> String {
        switch token {
        case .endOfLine:                           return ""
        case .atom(let value), .quoted(let value): return value
        case .number(let number):                  return String(number)
        case .nilValue:                            return "NIL"
        case .lparen:                              return "("
        case .rparen:                              return ")"
        case .lbracket:                            return "["
        case .rbracket:                            return "]"
        case .literal(let data):                   return String(bytes: data, encoding: .utf8) ?? ""
        }
    }

    /// Parses the envelope `date` string (per RFC 5322 `date-time`).
    static func parseEnvelopeDate(_ string: String) -> Date? {
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
    static func parseInternalDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}
