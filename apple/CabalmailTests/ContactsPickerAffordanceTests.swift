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

    // MARK: - Limited access (#1030)

    /// A `.limited` grant with nothing shared used to land on `.noCandidates`,
    /// which claims the address book is empty — false on a device holding
    /// contacts the user simply hasn't shared — and left the button inert.
    func testLimitedWithNothingSharedOffersToShareRatherThanClaimingAnEmptyBook() {
        XCTAssertEqual(affordance(.limited, hasCandidates: false), .shareMoreContacts)
        XCTAssertNotEqual(affordance(.limited, hasCandidates: false), .noCandidates)
    }

    func testTheShareMoreStateIsLiveAndLeadsSomewhere() {
        let state = affordance(.limited, hasCandidates: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.tintOpacity, 1, accuracy: 0.001)
    }

    /// The hint is the whole point: it has to describe the grant, not the
    /// device, and name the way out.
    func testTheShareMoreHintBlamesTheGrantAndNamesTheWayOut() {
        let hint = affordance(.limited, hasCandidates: false).hint(for: "To")
        XCTAssertTrue(hint.contains("shared"), hint)
        XCTAssertTrue(hint.contains("Privacy settings"), hint)
        XCTAssertFalse(hint.contains("No contacts with email addresses"), hint)
    }

    /// Full authorization is the only state where "there is nothing here"
    /// is a claim we can make about the device.
    func testOnlyFullAccessCanReportAnEmptyAddressBook() {
        for status in [ContactsAuthorizationStatus.limited, .notDetermined, .denied, .restricted] {
            XCTAssertNotEqual(affordance(status, hasCandidates: false), .noCandidates, "\(status)")
        }
    }

    // MARK: - Enabled controls look enabled, inert ones look inert

    func testOnlyTheNoCandidatesStateIsDisabled() {
        XCTAssertTrue(affordance(.authorized, hasCandidates: true).isEnabled)
        XCTAssertTrue(affordance(.notDetermined, hasCandidates: false).isEnabled)
        XCTAssertTrue(affordance(.denied, hasCandidates: false).isEnabled)
        XCTAssertTrue(affordance(.limited, hasCandidates: false).isEnabled)
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
        // `allCases`, not a hand-written list, so a state added later can't
        // slip past this invariant the way `.shareMoreContacts` would have.
        for state in ContactsPickerAffordance.allCases {
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
