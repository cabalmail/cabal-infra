import XCTest
@testable import CabalmailKit

final class AcknowledgementsTests: XCTestCase {
    func testBundlesMarkedAndTurndown() {
        let names = Set(Acknowledgements.bundledComponents().map(\.name))
        XCTAssertTrue(names.contains("marked"))
        XCTAssertTrue(names.contains("turndown"))
    }

    func testEveryComponentCarriesItsBundledLicenseText() {
        for component in Acknowledgements.bundledComponents() {
            XCTAssertEqual(component.license, "MIT", "\(component.name) license id")
            XCTAssertFalse(
                component.licenseText.isEmpty,
                "\(component.name) is missing its bundled license text — did sync-vendored.sh run?"
            )
            // The MIT grant clause is present in both vendored license files
            // (marked's also carries the original Markdown BSD notice, which
            // rides along in the same reproduced text).
            XCTAssertTrue(
                component.licenseText.contains("Permission is hereby granted"),
                "\(component.name) license text does not look like the MIT license"
            )
        }
    }
}
