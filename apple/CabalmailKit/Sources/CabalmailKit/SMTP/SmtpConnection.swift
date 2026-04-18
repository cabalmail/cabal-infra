import Foundation

/// Line-oriented wrapper around a `ByteStream` for the small subset of SMTP
/// we speak during submission: EHLO, AUTH PLAIN, MAIL FROM, RCPT TO, DATA,
/// QUIT. No pipelining, no literal handling — just CRLF-terminated ASCII.
actor SmtpConnection {
    private let stream: ByteStream
    private var buffer: Data = Data()
    private var closed = false

    init(stream: ByteStream) {
        self.stream = stream
    }

    func readResponse() async throws -> SmtpResponse {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try await readLine()
            guard line.count >= 4 else {
                throw CabalmailError.protocolError("Short SMTP line: \(line)")
            }
            let codeString = String(line.prefix(3))
            guard let parsed = Int(codeString) else {
                throw CabalmailError.protocolError("Non-numeric SMTP code: \(codeString)")
            }
            code = parsed
            let separatorIndex = line.index(line.startIndex, offsetBy: 3)
            let separator = line[separatorIndex]
            lines.append(String(line.suffix(from: line.index(after: separatorIndex))))
            if separator == " " { break }
            if separator != "-" {
                throw CabalmailError.protocolError("Unexpected SMTP continuation: \(line)")
            }
        }
        return SmtpResponse(code: code, lines: lines)
    }

    func writeLine(_ line: String) async throws {
        try await stream.write("\(line)\r\n")
    }

    /// Writes a DATA payload with dot-stuffing per RFC 5321 §4.5.2, followed
    /// by the terminating `.` line. Does not append a trailing CRLF to the
    /// message body — callers are expected to provide a well-formed RFC 5322
    /// payload already terminated by CRLF.
    func writeDataPayload(_ payload: Data) async throws {
        // Dot-stuffing: any line beginning with `.` gets an extra `.` prepended.
        let stuffed = dotStuff(payload)
        try await stream.write(stuffed)
        if let last = payload.last, last != UInt8(ascii: "\n") {
            try await stream.write("\r\n")
        }
        try await stream.write(".\r\n")
    }

    func close() async {
        if closed { return }
        closed = true
        await stream.close()
    }

    private func readLine() async throws -> String {
        while true {
            if let offset = firstCRLF(in: buffer) {
                let line = Data(Array(buffer.prefix(offset)))
                buffer.removeFirst(offset + 2)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = try await stream.read()
            guard !chunk.isEmpty else {
                throw CabalmailError.transport("SMTP stream closed mid-line")
            }
            buffer.append(chunk)
        }
    }

    /// Scans for CRLF as a Sequence rather than Int-subscripting the `Data`.
    /// After successive `removeFirst` calls, Data's internal `startIndex` may
    /// be non-zero — `data[0]` then traps. `for byte in data` always walks
    /// the logical element sequence safely.
    private func firstCRLF(in data: Data) -> Int? {
        if data.count < 2 { return nil }
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

    private func dotStuff(_ data: Data) -> Data {
        var result = Data(capacity: data.count)
        var atLineStart = true
        for byte in data {
            if atLineStart && byte == UInt8(ascii: ".") {
                result.append(UInt8(ascii: "."))
            }
            result.append(byte)
            atLineStart = (byte == UInt8(ascii: "\n"))
        }
        return result
    }
}

public struct SmtpResponse: Sendable, Equatable {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// True when the status code indicates success (2xx) or an expected
    /// intermediate (3xx during DATA). Errors are 4xx (transient) or 5xx
    /// (permanent).
    public var isOK: Bool { code >= 200 && code < 400 }
}
