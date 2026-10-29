import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How an image dropped or pasted into the Rich Text body travels inline.
public enum InlineImageEncoding {
    /// An image ready to go inline.
    public struct Encoded: Equatable, Sendable {
        public let data: Data
        public let format: ImageDataFormat

        public init(data: Data, format: ImageDataFormat) {
            self.data = data
            self.format = format
        }
    }

    /// Formats that go inline as they are: the ones every mail reader shows.
    static let portable: Set<ImageDataFormat> = [.jpeg, .png, .gif]

    /// The longest side a re-encoded image keeps: plenty for a message
    /// body, and it keeps a 48-megapixel photo from coming out larger as a
    /// JPEG than it went in.
    static let maxReencodedPixels = 4096

    /// The bytes to send `data` inline as, or nil when it is no image to
    /// show inline. JPEG, PNG and GIF go as they are. Any other image the
    /// device can read (HEIC from the photo library, WebP, TIFF, …) is
    /// re-encoded as JPEG no larger than `maxReencodedPixels` on its longest
    /// side, since many mail readers show none of those; one it can't read
    /// is nil, for the caller to attach. Decodes the image, so call it off
    /// the main actor.
    public static func encode(_ data: Data) -> Encoded? {
        guard let format = ImageDataFormat.detect(data) else { return nil }
        if portable.contains(format) {
            return Encoded(data: data, format: format)
        }
        guard let jpeg = jpeg(from: data) else { return nil }
        return Encoded(data: jpeg, format: .jpeg)
    }

    /// The image's first frame as JPEG, keeping its orientation.
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImageDestinationImageMaxPixelSize: maxReencodedPixels,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
