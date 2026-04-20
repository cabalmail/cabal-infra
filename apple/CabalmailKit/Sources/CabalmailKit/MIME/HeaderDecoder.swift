import Foundation

/// Decodes RFC 2047 encoded-words inside a header value.
///
/// Encoded-words look like `=?charset?(Q|B)?text?=` and can appear multiple
/// times in a single value. Each word decodes independently; non-encoded
/// runs between words stay as-is. Whitespace immediately between two
/// adjacent encoded-words is stripped per RFC 2047 §6.2.
enum HeaderDecoder {
    static func decode(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        let matches = regex.matches(in: value, range: range)
        if matches.isEmpty { return value }

        var output = ""
        var cursor = value.startIndex
        var lastWasEncoded = false
        for match in matches {
            guard let matchRange = Range(match.range, in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let textRange = Range(match.range(at: 3), in: value) else { continue }

            appendGap(
                from: cursor,
                to: matchRange.lowerBound,
                in: value,
                into: &output,
                lastWasEncoded: lastWasEncoded
            )

            let charset = String(value[charsetRange])
            let flag = value[encodingRange].first.map { String($0).uppercased() } ?? "Q"
            let payload = String(value[textRange])
            output.append(decodeWord(charset: charset, flag: flag, payload: payload) ?? "")

            cursor = matchRange.upperBound
            lastWasEncoded = true
        }
        if cursor < value.endIndex {
            output.append(String(value[cursor...]))
        }
        return output
    }

    /// Appends the characters between two encoded-word matches, obeying
    /// RFC 2047 §6.2 (whitespace between adjacent encoded-words is dropped).
    private static func appendGap(
        from cursor: String.Index,
        to nextMatchStart: String.Index,
        in value: String,
        into output: inout String,
        lastWasEncoded: Bool
    ) {
        let gap = value[cursor..<nextMatchStart]
        if lastWasEncoded, gap.allSatisfy({ $0.isWhitespace }) {
            return
        }
        output.append(String(gap))
    }

    private static func decodeWord(charset: String, flag: String, payload: String) -> String? {
        let encoding = stringEncoding(for: charset)
        let bytes: Data?
        switch flag {
        case "B":
            bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        case "Q":
            bytes = decodeQEncoded(payload)
        default:
            return nil
        }
        guard let bytes else { return nil }
        return String(bytes: bytes, encoding: encoding)
    }

    private static func decodeQEncoded(_ text: String) -> Data? {
        var output: [UInt8] = []
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "_") {
                output.append(UInt8(ascii: " "))
                index += 1
                continue
            }
            if byte == UInt8(ascii: "="), index + 2 < bytes.count,
               let high = hexDigit(bytes[index + 1]),
               let low = hexDigit(bytes[index + 2]) {
                output.append(UInt8(high * 16 + low))
                index += 3
                continue
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    private static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":           return .utf8
        case "iso-8859-1", "latin1":    return .isoLatin1
        case "us-ascii", "ascii":       return .ascii
        case "windows-1252":            return .windowsCP1252
        default:                        return .utf8
        }
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
