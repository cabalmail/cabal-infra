import os
import XCTest
@testable import CabalmailKit

/// The log facade (workstream 0.7). It used to hand each line to its own
/// unstructured `Task`, so a line reached the Debug Log some time after the
/// call and lines from one caller could land out of order (03-kit F16). Every
/// line now goes to the unified log and to the store before the call returns.
final class CabalmailLogTests: XCTestCase {
    /// A category no other test logs under, so the shared store's other
    /// traffic can be filtered out.
    private let category = "test-\(UUID().uuidString)"

    func testLinesAreInTheDebugLogInCallOrderWhenTheCallReturns() {
        for index in 0..<200 {
            CabalmailLog.info(category, "line \(index)")
        }
        let mine = DebugLogStore.shared.snapshot()
            .filter { $0.category == category }
            .map(\.message)
        XCTAssertEqual(mine, (0..<200).map { "line \($0)" })
    }

    func testEachLevelIsRecordedAsItself() {
        CabalmailLog.debug(category, "d")
        CabalmailLog.info(category, "i")
        CabalmailLog.warn(category, "w")
        CabalmailLog.error(category, "e")
        let levels = DebugLogStore.shared.snapshot()
            .filter { $0.category == category }
            .map(\.level)
        XCTAssertEqual(levels, [.debug, .info, .warn, .error])
    }

    func testTheMessageIsBuiltOnce() {
        var built = 0
        func message() -> String {
            built += 1
            return "built"
        }
        CabalmailLog.warn(category, message())
        XCTAssertEqual(built, 1)
    }

    func testRecordWritesToTheStoreItIsGiven() {
        let store = DebugLogStore(capacity: 4)
        CabalmailLog.record(.error, category, "private", into: store)
        XCTAssertEqual(store.snapshot().map(\.message), ["private"])
        XCTAssertFalse(
            DebugLogStore.shared.snapshot().contains { $0.category == category },
            "a line recorded into another store leaked into the shared one"
        )
    }

    /// Warnings stay apart from errors in the unified log.
    func testLevelsMapToTheUnifiedLogTypes() {
        XCTAssertEqual(DebugLogStore.Level.debug.osLogType, .debug)
        XCTAssertEqual(DebugLogStore.Level.info.osLogType, .info)
        XCTAssertEqual(DebugLogStore.Level.warn.osLogType, .default)
        XCTAssertEqual(DebugLogStore.Level.error.osLogType, .error)
    }
}
