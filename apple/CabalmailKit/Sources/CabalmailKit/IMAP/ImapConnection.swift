import Foundation

/// Wraps a `ByteStream` with IMAP-specific framing: per-command tag
/// generation, line reading with literal expansion, and response parsing.
///
/// One `ImapConnection` owns one logical IMAP session. Concurrent calls to
/// `sendCommand` are serialized by the actor — callers never juggle
/// interleaving themselves. For IDLE, callers obtain a dedicated connection
/// and drive it from a single task (no concurrent commands mid-IDLE).
actor ImapConnection {
    private let stream: ByteStream
    private var buffer: Data = Data()
    private var tagCounter: UInt64 = 0
    private var closed = false

    init(stream: ByteStream) {
        self.stream = stream
    }

    /// Reads the server's untagged greeting before any commands are issued.
    func readGreeting() async throws -> ImapResponse {
        try await readResponse()
    }

    /// Issues a command and collects every untagged response plus the tagged
    /// completion. Returns untagged responses first, completion last.
    ///
    /// - Parameters:
    ///   - command: The command body after the tag (e.g. `"LOGIN foo bar"`).
    ///   - literal: Optional literal payload for commands like `APPEND`. When
    ///     present, the command string must end with `{N}` (the caller
    ///     includes the size marker); `ImapConnection` waits for the `+`
    ///     continuation before sending the payload.
    @discardableResult
    func sendCommand(_ command: String, literal: Data? = nil) async throws -> [ImapResponse] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        try await stream.write("\(tag) \(command)\r\n")

        if let literal {
            while true {
                let response = try await readResponse()
                if case .continuation = response { break }
                if case let .completion(responseTag, _, text) = response, responseTag == tag {
                    throw CabalmailError.imapCommandFailed(status: "NO", detail: text)
                }
            }
            try await stream.write(literal)
            try await stream.write("\r\n")
        }

        var responses: [ImapResponse] = []
        while true {
            let response = try await readResponse()
            if case let .completion(responseTag, status, text) = response, responseTag == tag {
                responses.append(response)
                switch status {
                case .ok:
                    return responses
                case .no, .bad:
                    throw CabalmailError.imapCommandFailed(status: status.rawValue, detail: text)
                default:
                    return responses
                }
            }
            responses.append(response)
        }
    }

    /// Reads a single response from the stream. Used by `IDLE`, which cannot
    /// go through `sendCommand` — it has no tagged completion until the
    /// client issues `DONE`.
    func readUntagged() async throws -> ImapResponse {
        try await readResponse()
    }

    /// Writes arbitrary bytes — used by IDLE's `DONE` sentinel which has no
    /// command tag of its own.
    func writeRaw(_ string: String) async throws {
        try await stream.write(string)
    }

    func close() async {
        if closed { return }
        closed = true
        await stream.close()
    }

    // MARK: - Line reading

    private func readResponse() async throws -> ImapResponse {
        let (line, literals) = try await readLogicalLine()
        return ImapParser.parse(line: line, literals: literals)
    }

    /// Reads one logical IMAP response. A logical response is a CRLF-terminated
    /// line, but may contain any number of embedded literals (`{N}\r\n…N bytes`)
    /// that continue the same line. Literals are lifted out into the returned
    /// `literals` array; their positions in the line are marked with a single
    /// `ImapTokenizer.literalMarker` byte so the tokenizer can re-associate them.
    private func readLogicalLine() async throws -> (Data, [Data]) {
        var line = Data()
        var literals: [Data] = []
        while true {
            if let crlfOffset = firstCRLFIndex(in: buffer) {
                // Normalize with `Array(...)` so the fragment always has 0-based
                // indices. Raw Data.prefix returns a SubSequence that inherits
                // the original Data's startIndex, which may be non-zero after
                // successive `removeFirst` calls — subscripting that by Int 0
                // would then trap.
                let fragment = Data(Array(buffer.prefix(crlfOffset)))
                buffer.removeFirst(crlfOffset + 2)

                if let (prefixEnd, size) = extractLiteralHeader(from: fragment) {
                    line.append(Data(Array(fragment.prefix(prefixEnd))))
                    line.append(ImapTokenizer.literalMarker)
                    let literalBytes = try await readExact(size)
                    literals.append(literalBytes)
                    continue
                }
                line.append(fragment)
                return (line, literals)
            }
            let chunk = try await stream.read()
            guard !chunk.isEmpty else {
                throw CabalmailError.transport("IMAP stream closed mid-response")
            }
            buffer.append(chunk)
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await stream.read()
            guard !chunk.isEmpty else {
                throw CabalmailError.transport("IMAP stream closed mid-literal")
            }
            buffer.append(chunk)
        }
        let data = Data(Array(buffer.prefix(count)))
        buffer.removeFirst(count)
        return data
    }

    private func firstCRLFIndex(in data: Data) -> Int? {
        if data.count < 2 { return nil }
        // Iterate through the Data as a Sequence — the Int subscript on a
        // mutated Data can trap because `removeFirst` may preserve a non-zero
        // startIndex in the internal representation.
        var prev: UInt8 = 0
        var offset = 0
        for byte in data {
            if prev == 0x0D && byte == 0x0A {
                return offset - 1
            }
            prev = byte
            offset += 1
        }
        return nil
    }

    /// Detects a `{N}` literal header at the end of the fragment just before
    /// the CRLF. Returns the split point (byte index of the `{`) and the
    /// literal byte count. Returns nil if the fragment does not end with a
    /// valid literal header.
    ///
    /// Expects the fragment to be 0-indexed (call-sites normalize via
    /// `Data(Array(...))` before handing it in).
    private func extractLiteralHeader(from fragment: Data) -> (prefixEnd: Int, size: Int)? {
        let bytes = Array(fragment)
        guard let last = bytes.last, last == UInt8(ascii: "}") else { return nil }
        var cursor = bytes.count - 2
        while cursor >= 0 {
            let byte = bytes[cursor]
            if byte == UInt8(ascii: "{") { break }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            cursor -= 1
        }
        guard cursor >= 0, bytes[cursor] == UInt8(ascii: "{") else { return nil }
        let digitsStart = cursor + 1
        let digitsEnd = bytes.count - 1
        guard digitsEnd > digitsStart else { return nil }
        let digitSlice = Array(bytes[digitsStart..<digitsEnd])
        guard let digits = String(bytes: digitSlice, encoding: .ascii),
              let size = Int(digits) else { return nil }
        return (prefixEnd: cursor, size: size)
    }
}
