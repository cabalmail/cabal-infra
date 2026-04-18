import Foundation

/// Tokenizer for one fully-expanded IMAP response line.
///
/// "Fully-expanded" means literals (`{N}\r\n…N bytes…`) have already been
/// pulled into the byte stream by `ImapConnection`. The tokenizer doesn't
/// re-parse `{N}` markers; it just recognizes string/atom/number/list tokens
/// in the concatenated bytes.
struct ImapTokenizer {
    enum Token: Sendable, Equatable {
        case atom(String)
        case number(UInt64)
        case quoted(String)
        case literal(Data)
        case nilValue
        case lparen
        case rparen
        case lbracket
        case rbracket
        case endOfLine
    }

    private let bytes: [UInt8]
    private var index: Int = 0

    /// Marker placed by `ImapConnection.readResponseBytes` between an opening
    /// `{N}` header and the N bytes that follow, so the tokenizer can lift
    /// the literal out of the surrounding line without scanning for length.
    ///
    /// The byte value `0x00` is safe to use as a marker because IMAP atoms,
    /// quoted strings, and numbers cannot contain NUL, and the literal
    /// payload we care about (RFC 822 email bodies) is tunnelled separately
    /// so the tokenizer never needs to see the payload inline.
    static let literalMarker: UInt8 = 0x00

    /// Literal payloads extracted upstream. Keyed by the literal's order of
    /// appearance in the line.
    private var literals: [Data]
    private var literalCursor: Int = 0

    init(line: Data, literals: [Data] = []) {
        self.bytes = Array(line)
        self.literals = literals
    }

    mutating func next() -> Token {
        skipWhitespace()
        guard index < bytes.count else { return .endOfLine }
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "("):
            index += 1
            return .lparen
        case UInt8(ascii: ")"):
            index += 1
            return .rparen
        case UInt8(ascii: "["):
            index += 1
            return .lbracket
        case UInt8(ascii: "]"):
            index += 1
            return .rbracket
        case UInt8(ascii: "\""):
            return .quoted(readQuotedString())
        case Self.literalMarker:
            index += 1
            defer { literalCursor += 1 }
            let literal = literalCursor < literals.count ? literals[literalCursor] : Data()
            return .literal(literal)
        default:
            return readAtomOrNumber()
        }
    }

    /// Peek without consuming. Used by the parser when it needs to
    /// distinguish between end-of-list and next-attribute.
    mutating func peek() -> Token {
        let savedIndex = index
        let savedCursor = literalCursor
        let tok = next()
        index = savedIndex
        literalCursor = savedCursor
        return tok
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
                index += 1
            } else {
                return
            }
        }
    }

    private mutating func readQuotedString() -> String {
        // Precondition: bytes[index] == "
        index += 1
        var result: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") && index + 1 < bytes.count {
                // Quoted-string escape: only \\ and \" are defined by RFC 3501.
                result.append(bytes[index + 1])
                index += 2
            } else if byte == UInt8(ascii: "\"") {
                index += 1
                return String(bytes: result, encoding: .utf8) ?? ""
            } else {
                result.append(byte)
                index += 1
            }
        }
        return String(bytes: result, encoding: .utf8) ?? ""
    }

    private mutating func readAtomOrNumber() -> Token {
        var chars: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"),
                 UInt8(ascii: "("), UInt8(ascii: ")"),
                 UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: "\""),
                 UInt8(ascii: "\r"), UInt8(ascii: "\n"),
                 Self.literalMarker:
                break
            default:
                chars.append(byte)
                index += 1
                continue
            }
            break
        }
        let str = String(bytes: chars, encoding: .utf8) ?? ""
        if str.uppercased() == "NIL" {
            return .nilValue
        }
        if let number = UInt64(str) {
            return .number(number)
        }
        return .atom(str)
    }
}
