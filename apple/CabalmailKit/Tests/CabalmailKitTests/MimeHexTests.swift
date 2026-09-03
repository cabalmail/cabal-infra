import XCTest
@testable import CabalmailKit

/// Pins the `=HH` escape shared by the quoted-printable body decoder and the
/// header decoder's Q-encoding, plus the two call sites' handling of the
/// cases where the escape does not apply.
final class MimeHexTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - The shared escape

    func testDecodesBothDigitCases() {
        XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes("=3D")), 0x3D)
        XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes("=3d")), 0x3D)
        XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes("=E2")), 0xE2)
        XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes("=e2")), 0xE2)
        XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes("=Ab")), 0xAB)
    }

    func testDecodesEveryByteValue() {
        for value in UInt8.min...UInt8.max {
            XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes(String(format: "=%02X", value))), value)
            XCTAssertEqual(MimeHex.escapedByte(at: 0, in: bytes(String(format: "=%02x", value))), value)
        }
    }

    func testReadsTheEscapeAtAnOffset() {
        XCTAssertEqual(MimeHex.escapedByte(at: 2, in: bytes("ab=7Fcd")), 0x7F)
    }

    func testRejectsNonHexDigits() {
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=G0")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=0G")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("= 0")))
    }

    func testRejectsAnEscapeTruncatedByTheBufferEnd() {
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=4")))
        XCTAssertNil(MimeHex.escapedByte(at: 1, in: bytes("a=4")))
    }

    // MARK: - Quoted-printable bodies

    func testQuotedPrintableDecodesHexEscapes() {
        let decoded = MimeDecoders.decode(Data("a=3Db=e2=82=ACc".utf8), using: .quotedPrintable)
        XCTAssertEqual(decoded, Data([0x61, 0x3D, 0x62, 0xE2, 0x82, 0xAC, 0x63]))
    }

    func testQuotedPrintableSoftBreaksWinOverTheHexEscape() {
        XCTAssertEqual(MimeDecoders.decode(Data("a=\r\nb".utf8), using: .quotedPrintable), Data("ab".utf8))
        XCTAssertEqual(MimeDecoders.decode(Data("a=\nb".utf8), using: .quotedPrintable), Data("ab".utf8))
    }

    /// The quoted-printable decoder checks the two soft-break shapes before
    /// it tries the hex escape. The order is not load-bearing: CR and LF are
    /// not hex digits, so at most one of the two branches can ever match a
    /// given `=`. Pinned because that is what makes the escape safe to share.
    func testSoftBreakBytesAreNeverHexDigits() {
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=\r\n")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=\na")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=0\n")))
        XCTAssertNil(MimeHex.escapedByte(at: 0, in: bytes("=\r0")))
    }

    func testQuotedPrintablePassesAMalformedEscapeThrough() {
        XCTAssertEqual(MimeDecoders.decode(Data("a=zzb".utf8), using: .quotedPrintable), Data("a=zzb".utf8))
        XCTAssertEqual(MimeDecoders.decode(Data("a=4".utf8), using: .quotedPrintable), Data("a=4".utf8))
        XCTAssertEqual(MimeDecoders.decode(Data("a=".utf8), using: .quotedPrintable), Data("a=".utf8))
    }

    // MARK: - Q-encoded headers

    func testQEncodedHeaderDecodesHexEscapes() {
        XCTAssertEqual(HeaderDecoder.decode("=?utf-8?Q?a=3Db?="), "a=b")
        XCTAssertEqual(HeaderDecoder.decode("=?utf-8?Q?=C3=A9t=C3=A9?="), "été")
    }

    func testQEncodedHeaderKeepsUnderscoreAsSpaceAndPassesMalformedEscapes() {
        XCTAssertEqual(HeaderDecoder.decode("=?us-ascii?Q?Hello_World?="), "Hello World")
        XCTAssertEqual(HeaderDecoder.decode("=?us-ascii?Q?a=zzb?="), "a=zzb")
        XCTAssertEqual(HeaderDecoder.decode("=?us-ascii?Q?ab=4?="), "ab=4")
        XCTAssertEqual(HeaderDecoder.decode("=?us-ascii?Q?ab=?="), "ab=")
    }
}
