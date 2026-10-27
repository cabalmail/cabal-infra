import XCTest
@testable import CabalmailUI

/// The iPhone Duo spec's dialog rule for book pose: a confirmation dialog's
/// popover lands within 44 pt of the crease, so while a fold runs top to
/// bottom through the window the question comes up as an alert instead,
/// which stays clear of it. `confirmationPrompt` applies the rule; the
/// routing scan below holds every dialog in the shared app layer to it.
final class ConfirmationPromptTests: XCTestCase {

    // MARK: - The rule

    func testAnIPhoneWithAVerticalFoldPresentsAnAlert() {
        XCTAssertTrue(ConfirmationDialogPolicy.presentsAsAlert(on: .iOS, foldIsVertical: true))
    }

    /// Flat, closed, laptop pose and every iPhone and iPad without a fold
    /// keep the dialog they have today.
    func testAnIPhoneWithoutOneKeepsTheDialog() {
        XCTAssertFalse(ConfirmationDialogPolicy.presentsAsAlert(on: .iOS, foldIsVertical: false))
    }

    /// macOS presents these dialogs as alerts already, and visionOS and
    /// watchOS have no fold; none of them changes, whatever it is told.
    func testOtherPlatformsNeverSwitch() {
        for platform in [HostPlatform.macOS, .visionOS, .watchOS] {
            XCTAssertFalse(
                ConfirmationDialogPolicy.presentsAsAlert(on: platform, foldIsVertical: true),
                "\(platform)"
            )
            XCTAssertFalse(ConfirmationDialogPolicy.presentsAsAlert(on: platform, foldIsVertical: false))
        }
    }

    /// The host that runs these tests is the Mac, where a fold reading must
    /// not turn the app's dialogs into anything new.
    func testThisHostNeverSwitches() {
        XCTAssertEqual(HostPlatform.current, .macOS)
        XCTAssertFalse(ConfirmationDialogPolicy.presentsAsAlert(on: .current, foldIsVertical: true))
    }

    // MARK: - Routing

    /// Every dialog in the shared app layer goes through the wrapper, so a
    /// new one cannot bypass the fold. The wrapper's own forwarding call is
    /// the one `confirmationDialog` left, and it asks the rule.
    func testEveryDialogInTheAppLayerGoesThroughTheWrapper() throws {
        let sources = try Self.appLayerSources()
        XCTAssertGreaterThan(sources.count, 40, "floor: an empty or mis-rooted scan would pass everything vacuously")

        let wrapper = "CabalmailUI/Platform/ConfirmationPrompt.swift"
        let direct = sources
            .filter { $0.key != wrapper && $0.value.contains(".confirmationDialog(") }
            .map(\.key)
            .sorted()
        XCTAssertEqual(direct, [], "a dialog here must use .confirmationPrompt so it follows the fold")

        let prompts = sources.values.reduce(0) { $0 + $1.components(separatedBy: ".confirmationPrompt(").count - 1 }
        XCTAssertGreaterThan(prompts, 15, "too few prompts found to be scanning the app layer")

        let body = try XCTUnwrap(sources[wrapper], "the wrapper left the corpus")
        XCTAssertEqual(body.components(separatedBy: ".confirmationDialog(").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: ".alert(").count - 1, 1)
        XCTAssertTrue(body.contains("ConfirmationDialogPolicy.presentsAsAlert(on: .current"))
    }

    /// Every Swift source under `apple/CabalmailUI/`, keyed by its path under
    /// `apple/`.
    private static func appLayerSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        let root = apple.appendingPathComponent("CabalmailUI")
        var found: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return found
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let key = url.standardizedFileURL.path
                .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
            found[key] = try String(contentsOf: url, encoding: .utf8)
        }
        return found
    }
}
