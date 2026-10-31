import XCTest

// Every address list reads the list again when an address changes anywhere
// in the process (`AppState.addressesChanged()`, #2287): the inspector, the
// laptop panel's list, the compact Addresses tab, and another window's. A
// change made without the signal leaves every list on screen showing the
// old list until it is reopened, which is what the reader's Revoke, compose's
// New Address and the address intents did. The call sites are views and
// intents with no unit seam, so this reads the source, in the shape the
// other `*SourceScanTests` set: every app file that changes an address
// through the client also sends the signal.
final class AddressChangeSignalSourceScanTests: XCTestCase {

    /// The client calls that change the address list.
    private static let changes = [
        "client.requestAddress(",
        "client.revokeAddress(",
        "client.suspendAddress(",
        "client.reinstateAddress(",
        "client.setFavorite(address:",
    ]

    /// Whether `body` sends the signal: the call itself, the intents' shared
    /// tail, which sends it (pinned below), or the lists' model calling the
    /// `changed` hook its view hands it (`AddressesViewModel`, pinned in
    /// `LaptopAddressesWiringSourceScanTests`).
    private static func signals(_ body: String) -> Bool {
        body.contains("addressesChanged()")
            || body.contains("finishAddressCreation(")
            || body.range(of: #"(?m)^\s*changed\(\)$"#, options: .regularExpression) != nil
    }

    func testEveryAddressChangeTellsTheLists() throws {
        var changers: [String] = []
        for (path, body) in try Self.appSources() where Self.changes.contains(where: body.contains) {
            changers.append(path)
            XCTAssertTrue(
                Self.signals(body),
                "\(path) changes an address without AppState.addressesChanged(): "
                    + "the lists on screen keep the old list"
            )
        }
        // The lists' model, the new-address sheet, the reader's address menu
        // and the two intents: a scan that finds fewer has lost its anchors.
        XCTAssertGreaterThanOrEqual(changers.count, 5, "found only \(changers.sorted())")
    }

    func testTheIntentsSharedTailSendsTheSignal() throws {
        let body = try String(
            contentsOf: Self.apple.appendingPathComponent("Cabalmail/Intents/IntentSupport.swift"), encoding: .utf8
        )
        XCTAssertTrue(body.contains("func finishAddressCreation("))
        XCTAssertTrue(body.contains("IntentBridge.shared.appState?.addressesChanged()"))
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    /// The Swift sources of the shared app layer and the iOS app, by path
    /// relative to `apple/`.
    private static func appSources() throws -> [(String, String)] {
        var sources: [(String, String)] = []
        for folder in ["CabalmailUI", "Cabalmail", "CabalmailMac"] {
            let root = apple.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = folder + url.path.dropFirst(root.path.count)
                sources.append((path, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return sources
    }
}
