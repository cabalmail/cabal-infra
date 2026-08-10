import XCTest
import CabalmailKit
@testable import Cabalmail

/// Issue #1003: the compose Contacts buttons rendered in full accent green
/// while `.disabled(candidates.isEmpty)` held them inert, and an unauthorized
/// Contacts store made `allEntries()` return empty forever with no way to
/// grant access from compose. Both halves are decided here.
final class ContactsPickerAffordanceTests: XCTestCase {
    private func affordance(
        _ status: ContactsAuthorizationStatus,
        hasCandidates: Bool
    ) -> ContactsPickerAffordance {
        ContactsPickerAffordance(authorization: status, hasCandidates: hasCandidates)
    }

    // MARK: - Which outcome a tap gets

    func testAuthorizedWithCandidatesOpensThePicker() {
        XCTAssertEqual(affordance(.authorized, hasCandidates: true), .pick)
        XCTAssertEqual(affordance(.limited, hasCandidates: true), .pick)
    }

    func testUndeterminedAccessAsksRatherThanSittingInert() {
        // The reported case: no path from compose to a Contacts grant.
        XCTAssertEqual(affordance(.notDetermined, hasCandidates: false), .requestAccess)
    }

    func testRefusedAccessLeadsToTheSystemPrivacyPane() {
        XCTAssertEqual(affordance(.denied, hasCandidates: false), .openSystemSettings)
        XCTAssertEqual(affordance(.restricted, hasCandidates: false), .openSystemSettings)
    }

    func testAuthorizedButEmptyAddressBookHasNothingToOffer() {
        XCTAssertEqual(affordance(.authorized, hasCandidates: false), .noCandidates)
    }

    // MARK: - Enabled controls look enabled, inert ones look inert

    func testOnlyTheNoCandidatesStateIsDisabled() {
        XCTAssertTrue(affordance(.authorized, hasCandidates: true).isEnabled)
        XCTAssertTrue(affordance(.notDetermined, hasCandidates: false).isEnabled)
        XCTAssertTrue(affordance(.denied, hasCandidates: false).isEnabled)
        XCTAssertFalse(affordance(.authorized, hasCandidates: false).isEnabled)
    }

    func testTheDisabledStateIsDimmedAndTheLiveOnesAreNot() {
        // The defect: an empty candidate list disabled the button but left it
        // rendering at full accent strength, indistinguishable from live.
        XCTAssertEqual(affordance(.authorized, hasCandidates: false).tintOpacity, 0.35, accuracy: 0.001)
        XCTAssertEqual(affordance(.authorized, hasCandidates: true).tintOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(affordance(.denied, hasCandidates: false).tintOpacity, 1, accuracy: 0.001)
    }

    func testEveryStateThatLooksLiveHasSomethingToDo() {
        let states: [ContactsPickerAffordance] = [.pick, .requestAccess, .openSystemSettings, .noCandidates]
        for state in states {
            XCTAssertEqual(
                state.isEnabled,
                state.tintOpacity == 1,
                "\(state) renders live but is disabled, or vice versa"
            )
        }
    }

    // MARK: - Hints

    func testHintNamesTheFieldAndTheOutcome() {
        XCTAssertEqual(affordance(.authorized, hasCandidates: true).hint(for: "Bcc"),
                       "Pick Bcc recipients from Contacts")
        XCTAssertTrue(affordance(.notDetermined, hasCandidates: false).hint(for: "Cc").contains("Allow access"))
        XCTAssertTrue(affordance(.denied, hasCandidates: false).hint(for: "To").contains("Privacy settings"))
        XCTAssertTrue(affordance(.authorized, hasCandidates: false).hint(for: "To").contains("No contacts"))
    }
}
