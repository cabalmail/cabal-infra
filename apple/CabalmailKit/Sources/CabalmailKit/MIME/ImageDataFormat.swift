import Foundation

/// The image format a blob of bytes actually is, read from its magic number.
///
/// The photo picker hands back the asset's *native* encoding —  PNG for a
/// screenshot or a saved web image, HEIC for most camera captures on a
/// recent device — but the composer used to announce every one of them as
/// `image/jpeg` with a `.jpg` name. Recipients that trust the declared type
/// or the extension then fail to render a part whose bytes are fine, and
/// "save attachment" writes a `.jpg` that is not a JPEG (#1140).
///
/// Sniffing rather than asking the picker on purpose: the bytes are what
/// actually goes on the wire, so they are the only thing that can be wrong
/// about themselves. The picker's `supportedContentTypes` is a reasonable
/// fallback for a format not listed here, and the call site uses it as one.
public enum ImageDataFormat: String, Sendable, CaseIterable {
    case jpeg
    case png
    case gif
    case heic
    case avif
    case webp
    case tiff
    case bmp

    /// The `Content-Type` this format travels under.
    public var mimeType: String { "image/\(rawValue)" }

    /// The filename extension to hand a recipient. Only JPEG differs from
    /// the format name, and only because `.jpg` is what everything else
    /// writes.
    public var filenameExtension: String { self == .jpeg ? "jpg" : rawValue }

    /// ISO base-media brands that mean HEIF-family still images. `mif1` /
    /// `msf1` are the generic image / image-sequence brands Apple stamps on
    /// some captures, so matching only `heic` misses real HEICs.
    private static let heifBrands: Set<String> = [
        "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"
    ]

    /// Signatures that sit at the very start of the file. The two container
    /// formats below do not, so they are matched separately.
    private static let signatures: [(bytes: [UInt8], format: ImageDataFormat)] = [
        ([0xFF, 0xD8, 0xFF], .jpeg),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .png),
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], .gif),       // GIF87a
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], .gif),       // GIF89a
        ([0x42, 0x4D], .bmp),                               // BM
        ([0x49, 0x49, 0x2A, 0x00], .tiff),                  // little-endian
        ([0x4D, 0x4D, 0x00, 0x2A], .tiff)                   // big-endian
    ]

    /// Reads the format out of the leading bytes, or `nil` when they match
    /// nothing known — an unrecognized blob must not be *guessed* at, since
    /// guessing is the defect this exists to fix.
    public static func detect(_ data: Data) -> ImageDataFormat? {
        // Every signature below fits in the first 12 bytes.
        guard data.count >= 12 else { return nil }
        let head = [UInt8](data.prefix(12))
        if let match = signatures.first(where: { head.starts(with: $0.bytes) }) {
            return match.format
        }
        return containerFormat(head)
    }

    /// RIFF and ISO base media each carry a length field between their tags,
    /// so neither can be matched as a leading run.
    private static func containerFormat(_ head: [UInt8]) -> ImageDataFormat? {
        if tag(head, at: 0) == "RIFF", tag(head, at: 8) == "WEBP" { return .webp }
        guard tag(head, at: 4) == "ftyp", let brand = tag(head, at: 8) else { return nil }
        if brand == "avif" || brand == "avis" { return .avif }
        return heifBrands.contains(brand) ? .heic : nil
    }

    /// The four-byte ASCII tag at `offset`, or `nil` when those bytes are
    /// not ASCII — which is itself an answer: no tag, no container.
    private static func tag(_ bytes: [UInt8], at offset: Int) -> String? {
        String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
    }
}
