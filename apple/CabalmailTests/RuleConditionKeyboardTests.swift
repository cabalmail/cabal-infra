import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Which keyboard a rule condition's value field asks for (#2022): the
/// address headers get the email keyboard, the free-text fields keep the
/// plain one.
final class RuleConditionKeyboardTests: XCTestCase {
    func testAddressHeadersGetTheEmailKeyboard() {
        for field in [Rule.Field.from, .to, .cc] {
            XCTAssertEqual(field.conditionValueEntry, .email, "\(field)")
        }
    }

    func testFreeTextFieldsKeepThePlainKeyboard() {
        for field in [Rule.Field.subject, .body] {
            XCTAssertEqual(field.conditionValueEntry, .verbatim, "\(field)")
        }
    }
}
