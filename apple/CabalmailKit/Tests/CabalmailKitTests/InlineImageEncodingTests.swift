import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CabalmailKit

/// What an image dropped or pasted into the Rich Text body goes inline as.
final class InlineImageEncodingTests: XCTestCase {
    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    func testAFormatEveryReaderShowsGoesAsItIs() throws {
        let encoded = try XCTUnwrap(InlineImageEncoding.encode(Self.png))

        XCTAssertEqual(encoded.format, .png)
        XCTAssertEqual(encoded.data, Self.png)
    }

    func testAnImageFewReadersShowGoesAsJPEG() throws {
        let tiff = try Self.encode(Self.png, as: .tiff)
        XCTAssertEqual(ImageDataFormat.detect(tiff), .tiff)

        let encoded = try XCTUnwrap(InlineImageEncoding.encode(tiff))

        XCTAssertEqual(encoded.format, .jpeg)
        XCTAssertEqual(ImageDataFormat.detect(encoded.data), .jpeg)
    }

    func testAPhotoLibraryHEICGoesAsJPEG() throws {
        let heic: Data
        do {
            heic = try Self.encode(Self.png, as: .heic)
        } catch {
            throw XCTSkip("this runner can't encode HEIC to make the fixture")
        }

        let encoded = try XCTUnwrap(InlineImageEncoding.encode(heic))

        XCTAssertEqual(encoded.format, .jpeg)
        XCTAssertEqual(ImageDataFormat.detect(encoded.data), .jpeg)
    }

    func testWhatIsNoImageIsLeftForTheCallerToAttach() {
        XCTAssertNil(InlineImageEncoding.encode(Data("%PDF-1.7 not an image".utf8)))
        // A recognised signature with nothing readable behind it.
        XCTAssertNil(InlineImageEncoding.encode(Data([0x49, 0x49, 0x2A, 0x00]) + Data(count: 16)))
    }

    private struct EncodingFailed: Error {}

    private static func encode(_ data: Data, as type: UTType) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw EncodingFailed() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { throw EncodingFailed() }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodingFailed() }
        return output as Data
    }
}
