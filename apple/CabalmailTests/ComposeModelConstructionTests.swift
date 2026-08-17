import XCTest
import CabalmailKit
@testable import Cabalmail

/// Opening one compose surface must build exactly one `ComposeViewModel`
/// — each one owns a `RichTextEditorController` and its `WKWebView`, and
/// SwiftUI re-creates the view struct on every body evaluation of the
/// parent (#1102). The seam is `ComposeView`'s `@autoclosure` init plus
/// `DeferredComposeModel`: constructing the view must cost nothing, and
/// the holder SwiftUI keeps must vend one model however often it is read.
@MainActor
final class ComposeModelConstructionTests: XCTestCase {
    /// Counts factory calls while handing back the same prebuilt model, so
    /// the assertions are about *how many times the factory ran*, not about
    /// what it returns.
    @MainActor
    private final class CountingFactory {
        private let model: ComposeViewModel
        private(set) var calls = 0

        init(model: ComposeViewModel) {
            self.model = model
        }

        func make() -> ComposeViewModel {
            calls += 1
            return model
        }
    }

    func testConstructingComposeViewBuildsNoModel() throws {
        let factory = CountingFactory(model: try TestFixtures.makeComposeModel())

        // Three view structs, as SwiftUI would create on three body
        // evaluations of ComposeWindowContent / the iPhone sheet builder.
        for _ in 0..<3 {
            _ = ComposeView(model: factory.make())
        }

        XCTAssertEqual(
            factory.calls,
            0,
            "Building a ComposeView must not construct a ComposeViewModel"
        )
    }

    func testHolderBuildsOneModelHoweverOftenItIsRead() throws {
        let expected = try TestFixtures.makeComposeModel()
        let factory = CountingFactory(model: expected)
        let holder = DeferredComposeModel(factory.make)

        XCTAssertEqual(factory.calls, 0, "The holder must not build eagerly")

        let first = holder.model
        let second = holder.model
        let third = holder.model

        XCTAssertEqual(factory.calls, 1)
        XCTAssertTrue(first === expected)
        XCTAssertTrue(second === first)
        XCTAssertTrue(third === first)
    }
}
