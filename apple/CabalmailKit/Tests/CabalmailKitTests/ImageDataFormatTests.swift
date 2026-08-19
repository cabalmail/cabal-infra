import XCTest
@testable import CabalmailKit

/// Regression coverage for issue #1140: photo attachments were announced as
/// `.jpg` / `image/jpeg` whatever the picked asset actually was.
///
/// The bytes were never transcoded — a seeded PNG arrived byte-identical
/// (md5 match, magic `89 50 4E 47`) inside a part labelled `image/jpeg` —
/// so recipients that trust the declared type or the extension fail to
/// render a perfectly good part, and "save attachment" writes a `.jpg` that
/// is not a JPEG.
///
/// The tester's third arm is the reason this went unnoticed: a stock
/// simulator photo really is a JPEG, so the constant label was right by
/// accident every time an earlier pass picked one. `testJpegIsStillJpeg`
/// below is that arm, kept as the control — a sniffer that returned `.png`
/// for everything would pass all the other cases.
final class ImageDataFormatTests: XCTestCase {

    /// A signature plus enough trailing bytes to clear the 12-byte minimum.
    private func blob(_ bytes: [UInt8]) -> Data {
        Data(bytes + [UInt8](repeating: 0, count: max(0, 16 - bytes.count)))
    }

    private func blob(_ string: String) -> Data {
        blob([UInt8](string.utf8))
    }

    // MARK: - The reported flow

    /// The exact magic number from the issue's `fetch_attachment` dump.
    func testPngIsDetected() {
        let png = blob([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(ImageDataFormat.detect(png), .png)
        XCTAssertEqual(ImageDataFormat.detect(png)?.mimeType, "image/png")
        XCTAssertEqual(ImageDataFormat.detect(png)?.filenameExtension, "png")
    }

    /// The control: the label the old code hardcoded is still what a
    /// genuine JPEG gets, so nothing regresses for the assets that were
    /// already labelled correctly.
    func testJpegIsStillJpeg() {
        let jpeg = blob([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(ImageDataFormat.detect(jpeg), .jpeg)
        XCTAssertEqual(ImageDataFormat.detect(jpeg)?.mimeType, "image/jpeg")
        XCTAssertEqual(ImageDataFormat.detect(jpeg)?.filenameExtension, "jpg")
    }

    // MARK: - The other formats a picker can hand back

    /// What the camera produces on any recent device, and the format the
    /// issue calls out as the other half of the problem. Apple stamps
    /// several brands on HEIF stills; matching only `heic` misses real ones.
    func testHeicBrandsAreDetected() {
        for brand in ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"] {
            let heic = blob("\u{0}\u{0}\u{0}\u{18}ftyp" + brand)
            XCTAssertEqual(ImageDataFormat.detect(heic), .heic, "brand \(brand)")
            XCTAssertEqual(ImageDataFormat.detect(heic)?.mimeType, "image/heic")
        }
    }

    /// Same container, different brand — must not be called HEIC.
    func testAvifIsNotHeic() {
        let avif = blob("\u{0}\u{0}\u{0}\u{18}ftypavif")
        XCTAssertEqual(ImageDataFormat.detect(avif), .avif)
        XCTAssertEqual(ImageDataFormat.detect(avif)?.mimeType, "image/avif")
    }

    func testGifBothVersions() {
        XCTAssertEqual(ImageDataFormat.detect(blob("GIF87a")), .gif)
        XCTAssertEqual(ImageDataFormat.detect(blob("GIF89a")), .gif)
    }

    /// The four bytes between `RIFF` and `WEBP` are a length, so the tag
    /// has to be read at offset 8 rather than matched as one run.
    func testWebpReadsThePaddedTag() {
        let webp = blob("RIFF\u{2c}\u{1}\u{0}\u{0}WEBP")
        XCTAssertEqual(ImageDataFormat.detect(webp), .webp)
        XCTAssertEqual(ImageDataFormat.detect(webp)?.mimeType, "image/webp")
    }

    func testTiffBothByteOrders() {
        XCTAssertEqual(ImageDataFormat.detect(blob([0x49, 0x49, 0x2A, 0x00])), .tiff)
        XCTAssertEqual(ImageDataFormat.detect(blob([0x4D, 0x4D, 0x00, 0x2A])), .tiff)
    }

    func testBmp() {
        XCTAssertEqual(ImageDataFormat.detect(blob([0x42, 0x4D])), .bmp)
    }

    // MARK: - Refusing to guess

    /// An unrecognized blob returns `nil` rather than a plausible answer.
    /// Guessing is the defect; the call site falls back to the picker's own
    /// declared type, and then to `application/octet-stream`.
    func testUnknownBytesAreNotGuessedAt() {
        XCTAssertNil(ImageDataFormat.detect(blob("not an image at all")))
        XCTAssertNil(ImageDataFormat.detect(blob([0x00, 0x01, 0x02, 0x03])))
    }

    /// Short reads must not trap on the 12-byte window.
    func testShortDataIsSafe() {
        for count in 0..<12 {
            let short = Data([UInt8](repeating: 0xFF, count: count))
            XCTAssertNil(ImageDataFormat.detect(short), "\(count) bytes")
        }
    }

    /// `ftyp` with a brand nobody knows is not an image — the ISO container
    /// also carries MP4 video, which must not come out labelled `image/*`.
    func testUnknownIsoBrandIsNotAnImage() {
        XCTAssertNil(ImageDataFormat.detect(blob("\u{0}\u{0}\u{0}\u{18}ftypmp42")))
    }

    /// Every case round-trips to a well-formed `image/*` pair, so a format
    /// added later cannot ship with an empty or malformed label.
    func testEveryCaseHasAnImageLabel() {
        for format in ImageDataFormat.allCases {
            XCTAssertTrue(format.mimeType.hasPrefix("image/"), "\(format)")
            XCTAssertFalse(format.filenameExtension.isEmpty, "\(format)")
        }
    }
}
