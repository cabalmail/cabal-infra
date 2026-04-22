import Foundation

/// Parses raw RFC 5322 + MIME bytes (as returned by `UID FETCH BODY.PEEK[]`)
/// into a `MimePart` tree.
///
/// Scope:
/// - RFC 5322 folded headers
/// - RFC 2045 Content-Type / Content-Disposition / Content-Transfer-Encoding
/// - RFC 2046 multipart/* traversal (arbitrary nesting)
/// - RFC 2047 encoded-word header decoding (via `HeaderDecoder`)
/// - Transfer-encoding decode: 7bit/8bit/binary/base64/quoted-printable
///
/// Known gaps (intentional, documented in `apple/README.md`):
/// - RFC 2231 extended parameters (charset+language in `filename*=...`)
/// - S/MIME, PGP/MIME
/// - `message/rfc822` nested messages (treated as opaque attachment parts)
public enum MimeParser {
    public static func parse(_ data: Data) -> MimePart {
        let (headerBytes, body) = splitHeadersAndBody(data)
        let headers = parseHeaders(headerBytes)
        return buildPart(headers: headers, body: body)
    }

    // MARK: - Header / body split

    private static func splitHeadersAndBody(_ data: Data) -> (Data, Data) {
        let bytes = Array(data)
        if let splitIndex = findBlankLine(in: bytes) {
            let headerBytes = Data(bytes[0..<splitIndex])
            let bodyStart = splitIndex + blankLineLength(at: splitIndex, in: bytes)
            let body = Data(bytes[bodyStart..<bytes.count])
            return (headerBytes, body)
        }
        return (Data(bytes), Data())
    }

    private static func findBlankLine(in bytes: [UInt8]) -> Int? {
        // Looks for either `\r\n\r\n` or `\n\n` (lenient).
        // `0..<(count - 1)` traps at runtime for empty input, so short-circuit.
        guard bytes.count >= 2 else { return nil }
        for index in 0..<(bytes.count - 1) {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               index + 3 < bytes.count,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index
            }
            if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                return index
            }
        }
        return nil
    }

    private static func blankLineLength(at index: Int, in bytes: [UInt8]) -> Int {
        // `\r\n\r\n` → 4, `\n\n` → 2.
        guard index < bytes.count else { return 0 }
        return bytes[index] == 0x0D ? 4 : 2
    }

    // MARK: - Header parse

    private static func parseHeaders(_ data: Data) -> [MimeHeader] {
        guard let text = String(bytes: data, encoding: .utf8)
              ?? String(bytes: data, encoding: .isoLatin1) else { return [] }
        // Normalize CRLF before splitting. Swift treats `\r\n` as a single
        // extended grapheme cluster, so `text.split(separator: "\n")` on
        // CRLF-delimited wire bytes returns one big "line" — which is why
        // folded-header unfolding has to happen on normalized text.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let unfolded = unfold(normalized)
        return unfolded.split(separator: "\n").compactMap(parseHeaderLine)
    }

    /// Joins any line beginning with whitespace onto its predecessor
    /// (RFC 5322 §2.2.3). Produces a `\n`-terminated stream.
    private static func unfold(_ text: String) -> String {
        var result = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.first == " " || line.first == "\t" {
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                result.append(" ")
                result.append(String(trimmed))
            } else {
                if !result.isEmpty { result.append("\n") }
                result.append(line)
            }
        }
        return result
    }

    private static func parseHeaderLine(_ line: Substring) -> MimeHeader? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let valueStart = line.index(after: colon)
        let rawValue = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        return MimeHeader(name: name, value: HeaderDecoder.decode(rawValue))
    }

    // MARK: - Part construction

    private static func buildPart(headers: [MimeHeader], body: Data) -> MimePart {
        let contentType = parseContentType(headers)
        let disposition = parseDisposition(headers)
        let contentID = findHeader(headers, "Content-ID")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
        let encoding = MimeEncoding(raw: findHeader(headers, "Content-Transfer-Encoding"))

        if contentType.isMultipart, let boundary = contentType.boundary {
            let parts = splitMultipart(body: body, boundary: boundary)
                .map { parse($0) }
            return MimePart(
                headers: headers,
                contentType: contentType,
                contentDisposition: disposition,
                contentID: contentID,
                encoding: encoding,
                decodedBody: Data(),
                children: parts
            )
        }

        let decoded = MimeDecoders.decode(body, using: encoding)
        return MimePart(
            headers: headers,
            contentType: contentType,
            contentDisposition: disposition,
            contentID: contentID,
            encoding: encoding,
            decodedBody: decoded,
            children: []
        )
    }

    // MARK: - Multipart split

    /// Splits the body on a boundary string per RFC 2046 §5.1.1.
    ///
    /// A boundary is `--<boundary>` on its own line; the terminal boundary
    /// is `--<boundary>--`. Content between occurrences is one part
    /// (including its own headers).
    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        let needle = Data("--\(boundary)".utf8)
        let occurrences = findOccurrences(of: needle, in: body)
        guard occurrences.count >= 2 else { return [] }
        var parts: [Data] = []
        for pair in occurrences.indices.dropLast() {
            let start = occurrences[pair] + needle.count
            let end = occurrences[pair + 1]
            var slice = Data(Array(body[start..<end]))
            slice = trimLeadingCRLF(slice)
            slice = trimTrailingCRLF(slice)
            parts.append(slice)
        }
        return parts
    }

    private static func findOccurrences(of needle: Data, in haystack: Data) -> [Int] {
        let hay = Array(haystack)
        let pin = Array(needle)
        guard !pin.isEmpty, hay.count >= pin.count else { return [] }
        var positions: [Int] = []
        var index = 0
        while index <= hay.count - pin.count {
            if matchesAt(index, haystack: hay, needle: pin) {
                // Boundary must be preceded by CRLF/LF (or be at position 0).
                let precededByNewline = index == 0
                    || hay[index - 1] == 0x0A
                    || (index >= 2 && hay[index - 2] == 0x0D && hay[index - 1] == 0x0A)
                if precededByNewline {
                    positions.append(index)
                    index += pin.count
                    continue
                }
            }
            index += 1
        }
        return positions
    }

    private static func matchesAt(_ offset: Int, haystack: [UInt8], needle: [UInt8]) -> Bool {
        for idx in 0..<needle.count where haystack[offset + idx] != needle[idx] {
            return false
        }
        return true
    }

    private static func trimLeadingCRLF(_ data: Data) -> Data {
        var bytes = Array(data)
        while let first = bytes.first, first == 0x0D || first == 0x0A {
            bytes.removeFirst()
        }
        return Data(bytes)
    }

    private static func trimTrailingCRLF(_ data: Data) -> Data {
        var bytes = Array(data)
        while let last = bytes.last, last == 0x0D || last == 0x0A {
            bytes.removeLast()
        }
        return Data(bytes)
    }

    // MARK: - Header lookups

    private static func findHeader(_ headers: [MimeHeader], _ name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.name.lowercased() == needle }?.value
    }

    private static func parseContentType(_ headers: [MimeHeader]) -> MimeContentType {
        guard let raw = findHeader(headers, "Content-Type") else {
            return .defaultPlainText
        }
        return parseTypeHeader(raw, defaultType: "text", defaultSubtype: "plain")
            .asContentType()
    }

    private static func parseDisposition(_ headers: [MimeHeader]) -> MimeContentDisposition? {
        guard let raw = findHeader(headers, "Content-Disposition") else { return nil }
        let parsed = parseTypeHeader(raw, defaultType: "inline", defaultSubtype: "")
        return MimeContentDisposition(type: parsed.type, parameters: parsed.parameters)
    }

    // Returned in a common shape because Content-Type and Content-Disposition
    // use the same `type; param=value; ...` grammar.
    private struct ParsedTypeHeader {
        let type: String
        let subtype: String
        let parameters: [String: String]

        func asContentType() -> MimeContentType {
            MimeContentType(type: type, subtype: subtype, parameters: parameters)
        }
    }

    private static func parseTypeHeader(
        _ raw: String,
        defaultType: String,
        defaultSubtype: String
    ) -> ParsedTypeHeader {
        let components = raw.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = components.first else {
            return ParsedTypeHeader(type: defaultType, subtype: defaultSubtype, parameters: [:])
        }
        let typeParts = first.split(separator: "/", maxSplits: 1).map(String.init)
        let type = typeParts.first ?? defaultType
        let subtype = typeParts.count > 1 ? typeParts[1] : defaultSubtype
        var parameters: [String: String] = [:]
        for component in components.dropFirst() {
            if let equals = component.firstIndex(of: "=") {
                let key = component[..<equals]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                var value = component[component.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                parameters[key] = value
            }
        }
        return ParsedTypeHeader(type: type, subtype: subtype, parameters: parameters)
    }
}
