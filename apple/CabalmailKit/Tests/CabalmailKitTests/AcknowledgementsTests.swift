import XCTest
@testable import CabalmailKit

final class AcknowledgementsTests: XCTestCase {
    func testBundlesMarkedTurndownAndReadability() {
        let names = Set(Acknowledgements.bundledComponents().map(\.name))
        XCTAssertTrue(names.contains("marked"))
        XCTAssertTrue(names.contains("turndown"))
        XCTAssertTrue(names.contains("Readability"))
    }

    func testEveryComponentCarriesItsBundledLicenseText() {
        for component in Acknowledgements.bundledComponents() {
            XCTAssertFalse(
                component.licenseText.isEmpty,
                "\(component.name) is missing its bundled license text — did sync-vendored.sh run?"
            )
            // Each license id must match the text that ships with it: the MIT
            // grant clause for marked and turndown (marked's also carries the
            // original Markdown BSD notice), the Apache heading for Readability.
            switch component.license {
            case "MIT":
                XCTAssertTrue(
                    component.licenseText.contains("Permission is hereby granted"),
                    "\(component.name) license text does not look like the MIT license"
                )
            case "Apache-2.0":
                XCTAssertTrue(
                    component.licenseText.localizedCaseInsensitiveContains("Apache License"),
                    "\(component.name) license text does not look like the Apache License"
                )
            default:
                XCTFail("\(component.name) has an unexpected license id \(component.license)")
            }
        }
    }
}
