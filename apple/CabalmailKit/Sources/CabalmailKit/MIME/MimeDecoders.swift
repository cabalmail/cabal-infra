import Foundation

/// Content-Transfer-Encoding decoders: base64 and quoted-printable.
///
/// Scope is only what a real Dovecot + user-agent mix sends us. Both
/// decoders are lenient on malformed input — they skip bad bytes rather
/// than throwing so a single broken part doesn't prevent the rest of the
/// message from rendering.
enum MimeDecoders {
    static func decode(_ body: Data, using encoding: MimeEncoding) -> Data {
        switch encoding {
        case .sevenBit, .eightBit, .binary:
            return body
        case .base64:
            return decodeBase64(body)
        case .quotedPrintable:
            return decodeQuotedPrintable(body)
        }
    }

    // Base64 bodies arrive CRLF-folded per RFC 2045 §6.8; Foundation's
    // base64 decoder rejects embedded whitespace unless we opt in.
    private static func decodeBase64(_ data: Data) -> Data {
        Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
    }

    // Quoted-printable per RFC 2045 §6.7. Two rules we care about:
    //   1. `=<hex><hex>` → the byte with that value.
    //   2. `=` at end of line (soft line break) → consume and drop the
    //      following CRLF.
    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                let consumed = handleEquals(at: index, in: bytes, output: &output)
                index += consumed
            } else {
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    /// Handles a `=`-prefixed sequence in a quoted-printable stream. Returns
    /// the number of bytes to advance past this sequence.
    private static func handleEquals(
        at index: Int,
        in bytes: [UInt8],
        output: inout [UInt8]
    ) -> Int {
        // Soft line break: `=\r\n` → drop all three.
        if index + 2 < bytes.count,
           bytes[index + 1] == 0x0D,
           bytes[index + 2] == 0x0A {
            return 3
        }
        // Tolerant soft break: `=\n` → drop both.
        if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
            return 2
        }
        // Hex escape: `=HH` → one output byte.
        if index + 2 < bytes.count,
           let high = hexDigit(bytes[index + 1]),
           let low = hexDigit(bytes[index + 2]) {
            output.append(UInt8(high * 16 + low))
            return 3
        }
        // Malformed — pass `=` through and move on.
        output.append(UInt8(ascii: "="))
        return 1
    }

    private static func hexDigit(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return Int(byte - UInt8(ascii: "A") + 10)
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return Int(byte - UInt8(ascii: "a") + 10)
        default:
            return nil
        }
    }
}
