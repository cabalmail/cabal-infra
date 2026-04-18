import Foundation

/// Abstract async byte channel used by `ImapConnection` and `SmtpConnection`.
///
/// Two concerns meet here: production code needs a TLS-capable socket, tests
/// need deterministic scripting. Rather than expose `NWConnection` directly
/// (which is not `Sendable`), the concrete stream types live behind this
/// protocol and the clients stay protocol-only.
public protocol ByteStream: Sendable {
    /// Reads the next chunk of bytes. Returns an empty `Data` if the peer
    /// closed cleanly; throws on I/O errors.
    func read() async throws -> Data

    /// Writes all of `data` before returning.
    func write(_ data: Data) async throws

    /// Upgrades the stream to TLS in-place, returning a new stream wrapping
    /// the upgraded connection. Used by SMTP's STARTTLS flow; IMAP connects
    /// over TLS from the start so only SMTP needs this.
    func startTLS(host: String) async throws -> ByteStream

    /// Closes the underlying connection. Safe to call multiple times.
    func close() async
}

public extension ByteStream {
    /// Convenience: writes a UTF-8 string. Used by IMAP/SMTP command
    /// assembly where every byte is ASCII.
    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }
}
