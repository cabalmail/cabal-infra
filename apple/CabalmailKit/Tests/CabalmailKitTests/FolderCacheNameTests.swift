import XCTest
@testable import CabalmailKit

/// The offline caches name a folder's files after the folder, and the old
/// name collapsed `/` and `.` into `_`: `a/b` and `a_b` were one file, so
/// each folder's snapshot replaced the other's and neither had a usable
/// offline copy of itself (#1871).
final class FolderCacheNameTests: XCTestCase {

    func testFoldersThatUsedToCollapseTogetherGetDifferentNames() {
        XCTAssertNotEqual(
            FolderCacheName.component(for: "a/b"),
            FolderCacheName.component(for: "a_b")
        )
        // The measured pair from the report, and the dotted spelling of the
        // same path the API normalizes with.
        XCTAssertNotEqual(
            FolderCacheName.component(for: "zzc/qq"),
            FolderCacheName.component(for: "zzc_qq")
        )
        XCTAssertNotEqual(
            FolderCacheName.component(for: "zzc.qq"),
            FolderCacheName.component(for: "zzc_qq")
        )
    }

    func testTheNameIsOnePathComponent() {
        // The reason the old code collapsed at all: a separator would nest
        // into real subdirectories.
        for folder in ["a/b", "Parent/Child/Leaf", "a:b", "../escape", "a\\b"] {
            let component = FolderCacheName.component(for: folder)
            XCTAssertFalse(component.contains("/"), folder)
            XCTAssertEqual(URL(fileURLWithPath: "/root").appendingPathComponent(component)
                .deletingLastPathComponent().path, "/root", folder)
        }
    }

    func testCaseOnlyDifferencesSurviveACaseInsensitiveFilesystem() {
        // APFS is case-insensitive by default; IMAP folder names are not.
        let upper = FolderCacheName.component(for: "Archive")
        let lower = FolderCacheName.component(for: "archive")
        XCTAssertNotEqual(upper.lowercased(), lower.lowercased())
    }

    func testTheNameIsStableAcrossCalls() {
        // Not `Hasher`, which is seeded per process — the same folder must
        // take the same file on the next launch or every cache is cold.
        XCTAssertEqual(
            FolderCacheName.component(for: "INBOX.Receipts"),
            FolderCacheName.component(for: "INBOX.Receipts")
        )
        // Pinned, so a change of scheme has to be a deliberate edit here
        // (and come with a migration, as this one did).
        XCTAssertEqual(FolderCacheName.component(for: "INBOX"), "INBOX.41c5c6eaa9e13dbb")
    }

    func testLegacyNamesAreNotMistakenForCurrentOnes() {
        XCTAssertFalse(FolderCacheName.isCurrent(base: "zzc_qq"))
        XCTAssertFalse(FolderCacheName.isCurrent(base: "INBOX"))
        XCTAssertFalse(FolderCacheName.isCurrent(base: "SoakParent_SoakChild"))
        XCTAssertTrue(FolderCacheName.isCurrent(base: FolderCacheName.component(for: "zzc/qq")))
        XCTAssertTrue(FolderCacheName.isCurrent(base: FolderCacheName.component(for: "INBOX")))
    }
}
