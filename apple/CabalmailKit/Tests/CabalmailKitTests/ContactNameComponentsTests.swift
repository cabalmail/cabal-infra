import XCTest
@testable import CabalmailKit

final class ContactNameComponentsTests: XCTestCase {
    func testTwoPartName() {
        let comps = ContactNameComponents.parse("Jane Smith")
        XCTAssertEqual(comps?.given, "Jane")
        XCTAssertEqual(comps?.family, "Smith")
        XCTAssertNil(comps?.middle)
    }

    func testThreePartNameFillsMiddle() {
        let comps = ContactNameComponents.parse("Mary Ann Smith")
        XCTAssertEqual(comps?.given, "Mary")
        XCTAssertEqual(comps?.middle, "Ann")
        XCTAssertEqual(comps?.family, "Smith")
    }

    func testInitialThenSurname() {
        let comps = ContactNameComponents.parse("J. Carr")
        XCTAssertEqual(comps?.given, "J.")
        XCTAssertEqual(comps?.family, "Carr")
    }

    func testHyphenatedSurnameStaysTogether() {
        let comps = ContactNameComponents.parse("David Lopez-Carr")
        XCTAssertEqual(comps?.given, "David")
        XCTAssertEqual(comps?.family, "Lopez-Carr")
    }

    func testSingleTokenBecomesGivenName() {
        let comps = ContactNameComponents.parse("Madonna")
        XCTAssertEqual(comps?.given, "Madonna")
        XCTAssertNil(comps?.middle)
        XCTAssertNil(comps?.family)
    }

    func testCommaIsAmbiguous() {
        XCTAssertNil(ContactNameComponents.parse("Smith, John"))
    }

    func testAddressFragmentIsRejected() {
        XCTAssertNil(ContactNameComponents.parse("jcarrjj@gmail.com"))
    }

    func testDigitsAreRejected() {
        XCTAssertNil(ContactNameComponents.parse("Room 204 Booking"))
    }

    func testLongOrgLabelIsRejected() {
        XCTAssertNil(ContactNameComponents.parse("Acme Widgets Sales And Support Team"))
    }

    func testEmptyAndNilReturnNil() {
        XCTAssertNil(ContactNameComponents.parse(nil))
        XCTAssertNil(ContactNameComponents.parse(""))
        XCTAssertNil(ContactNameComponents.parse("   "))
    }

    func testWhitespaceIsTrimmed() {
        let comps = ContactNameComponents.parse("  Jane Smith  ")
        XCTAssertEqual(comps?.given, "Jane")
        XCTAssertEqual(comps?.family, "Smith")
    }
}
