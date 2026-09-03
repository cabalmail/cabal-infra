import Foundation

/// The `=HH` hex escape, shared by the two decoders that read one: the
/// quoted-printable body decoder (RFC 2045 §6.7) and the header decoder's
/// Q-encoding (RFC 2047 §4.2). Same escape and the same tolerance for a
/// malformed one — both decoders pass the bare `=` through rather than
/// failing the part or the header it appears in.
enum MimeHex {
    /// The byte encoded by the escape whose `=` sits at `index`, or nil
    /// when the two bytes after it are not a complete hex pair — the
    /// buffer ends first, or either digit is not hex. Both digit cases are
    /// accepted. Callers advance three bytes on a hit.
    static func escapedByte(at index: Int, in bytes: [UInt8]) -> UInt8? {
        guard index + 2 < bytes.count,
              let high = digit(bytes[index + 1]),
              let low = digit(bytes[index + 2]) else { return nil }
        return UInt8(high * 16 + low)
    }

    private static func digit(_ byte: UInt8) -> Int? {
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
