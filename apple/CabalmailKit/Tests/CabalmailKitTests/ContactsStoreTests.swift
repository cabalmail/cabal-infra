import Contacts
import XCTest
@testable import CabalmailKit

final class ContactsStoreTests: XCTestCase {

    // MARK: - NoopContactsStore

    func testNoopReturnsDenied() async {
        let store = NoopContactsStore()
        let status = await store.authorizationStatus
        XCTAssertEqual(status, .denied)
        XCTAssertFalse(status.isAccessible)
    }

    func testNoopReturnsNilForEverything() async {
        let store = NoopContactsStore()
        let address = EmailAddress(name: nil, mailbox: "jdoe", host: "example.com")
        let name = await store.displayName(for: address)
        let photo = await store.photoData(for: address)
        let granted = await store.requestAccess()
        XCTAssertNil(name)
        XCTAssertNil(photo)
        XCTAssertFalse(granted)
    }

    // MARK: - ContactsAuthorizationStatus

    func testAuthorizationStatusMappingCoversAllCases() {
        XCTAssertEqual(ContactsAuthorizationStatus(.notDetermined), .notDetermined)
        XCTAssertEqual(ContactsAuthorizationStatus(.restricted), .restricted)
        XCTAssertEqual(ContactsAuthorizationStatus(.denied), .denied)
        XCTAssertEqual(ContactsAuthorizationStatus(.authorized), .authorized)
        // CNAuthorizationStatus.limited is iOS/visionOS only; the macOS
        // build of the Contacts framework marks it unavailable, so we can
        // only assert the mapping where the source case is reachable.
        #if os(iOS) || os(visionOS)
        XCTAssertEqual(ContactsAuthorizationStatus(.limited), .limited)
        #endif
    }

    func testIsAccessibleOnlyForAuthorizedAndLimited() {
        XCTAssertTrue(ContactsAuthorizationStatus.authorized.isAccessible)
        XCTAssertTrue(ContactsAuthorizationStatus.limited.isAccessible)
        XCTAssertFalse(ContactsAuthorizationStatus.notDetermined.isAccessible)
        XCTAssertFalse(ContactsAuthorizationStatus.denied.isAccessible)
        XCTAssertFalse(ContactsAuthorizationStatus.restricted.isAccessible)
    }

    // MARK: - bestDisplayName

    func testFullNamePrefersGivenAndFamily() {
        let contact = CNMutableContact()
        contact.givenName = "Jane"
        contact.familyName = "Doe"
        contact.nickname = "Janie"
        contact.organizationName = "Acme"

        let name = LiveContactsStore.bestDisplayName(for: contact)
        XCTAssertEqual(name, "Jane Doe")
    }

    func testFallsBackToNicknameWhenNoPersonName() {
        let contact = CNMutableContact()
        contact.nickname = "Slim"
        contact.organizationName = "Acme"

        let name = LiveContactsStore.bestDisplayName(for: contact)
        XCTAssertEqual(name, "Slim")
    }

    func testFallsBackToOrganizationWhenNoPersonOrNickname() {
        let contact = CNMutableContact()
        contact.organizationName = "Acme Corp"

        let name = LiveContactsStore.bestDisplayName(for: contact)
        XCTAssertEqual(name, "Acme Corp")
    }

    func testReturnsNilWhenAllNameFieldsEmpty() {
        let contact = CNMutableContact()

        let name = LiveContactsStore.bestDisplayName(for: contact)
        XCTAssertNil(name)
    }

    func testHonorsFamilyNameOnlyContacts() {
        let contact = CNMutableContact()
        contact.familyName = "Doe"

        let name = LiveContactsStore.bestDisplayName(for: contact)
        XCTAssertEqual(name, "Doe")
    }

    // MARK: - EmailAddress.contactsCacheKey

    func testCacheKeyLowercasesBothHalves() {
        let address = EmailAddress(name: nil, mailbox: "Jdoe", host: "Example.COM")
        XCTAssertEqual(address.contactsCacheKey, "jdoe@example.com")
    }

    func testCacheKeyMatchesAcrossCaseVariants() {
        let lower = EmailAddress(name: nil, mailbox: "jdoe", host: "example.com")
        let mixed = EmailAddress(name: "J. Doe", mailbox: "JDOE", host: "EXAMPLE.COM")
        XCTAssertEqual(lower.contactsCacheKey, mixed.contactsCacheKey)
    }
}
