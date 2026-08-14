import XCTest
import CoreGraphics
@testable import Cabalmail

/// The reader header lays recipients out with `FlowLayout`. A recipient
/// wider than the pane used to be placed at its unclamped ideal width and
/// hard-cut mid-string by the enclosing clip ("t27-0813@t27-0813.cabal-m"),
/// because wrapping *between* tokens can never narrow a single token.
final class FlowLayoutSolverTests: XCTestCase {
    private let solver = FlowLayoutSolver(horizontalSpacing: 4, verticalSpacing: 2)

    /// A token measured at `width` truncates: it takes the width it is given
    /// and keeps its single-line height.
    private func truncating(height: CGFloat = 10) -> (Int, CGFloat) -> CGSize {
        { _, width in CGSize(width: width, height: height) }
    }

    // MARK: - The invariant

    func testNoItemIsEverPlacedPastTheLineWidth() {
        let ideals = [
            CGSize(width: 20, height: 10),      // fits
            CGSize(width: 205, height: 10),     // the reported overflow
            CGSize(width: 60, height: 10),      // fits
            CGSize(width: 1_000, height: 10),   // far past the line
        ]
        let solution = solver.solve(idealSizes: ideals, lineWidth: 100, measure: truncating())

        for (index, frame) in solution.frames.enumerated() {
            XCTAssertLessThanOrEqual(
                frame.maxX, 100,
                "item \(index) is laid out \(frame.maxX - 100)pt past the container"
            )
        }
        XCTAssertLessThanOrEqual(solution.size.width, 100)
    }

    func testAnOversizedItemIsProposedTheLineWidthSoItCanTruncate() {
        var proposedWidths: [CGFloat] = []
        let measure: (Int, CGFloat) -> CGSize = { _, width in
            proposedWidths.append(width)
            return CGSize(width: width, height: 10)
        }
        let solution = solver.solve(
            idealSizes: [CGSize(width: 205.5, height: 10)],
            lineWidth: 175,
            measure: measure
        )

        XCTAssertEqual(proposedWidths, [175], "the overflowing token was never re-measured")
        XCTAssertEqual(solution.frames.first?.width, 175)
    }

    func testAWrappingItemKeepsTheTallerHeightItReportsAtTheNarrowerWidth() {
        // A token that wraps onto two lines rather than truncating.
        let wrapping: (Int, CGFloat) -> CGSize = { _, width in CGSize(width: width, height: 24) }
        let solution = solver.solve(
            idealSizes: [CGSize(width: 300, height: 12), CGSize(width: 30, height: 12)],
            lineWidth: 100,
            measure: wrapping
        )

        XCTAssertEqual(solution.frames[0].height, 24)
        // The neighbour lands on the next row, below the full wrapped height.
        XCTAssertEqual(solution.frames[1].origin, CGPoint(x: 0, y: 26))
        XCTAssertEqual(solution.size.height, 26 + 12)
    }

    // MARK: - The path that already worked

    func testItemsThatFitAreLeftAtTheirIdealSizeAndNeverRemeasured() {
        var remeasured = 0
        let solution = solver.solve(
            idealSizes: [CGSize(width: 30, height: 10), CGSize(width: 40, height: 10)],
            lineWidth: 100,
            measure: { _, width in remeasured += 1; return CGSize(width: width, height: 10) }
        )

        XCTAssertEqual(remeasured, 0)
        XCTAssertEqual(solution.frames.map(\.width), [30, 40])
        XCTAssertEqual(solution.frames.map(\.minX), [0, 34])
        XCTAssertEqual(solution.size, CGSize(width: 74, height: 10))
    }

    func testItemsWrapToTheNextRowWhenTheLineIsFull() {
        let solution = solver.solve(
            idealSizes: [CGSize(width: 60, height: 10), CGSize(width: 50, height: 12)],
            lineWidth: 100,
            measure: truncating()
        )

        XCTAssertEqual(solution.frames[0], CGRect(x: 0, y: 0, width: 60, height: 10))
        XCTAssertEqual(solution.frames[1], CGRect(x: 0, y: 12, width: 50, height: 12))
        XCTAssertEqual(solution.size, CGSize(width: 60, height: 24))
    }

    func testAnUnboundedLineLeavesEveryItemAtItsIdealWidth() {
        let solution = solver.solve(
            idealSizes: [CGSize(width: 205, height: 10), CGSize(width: 30, height: 10)],
            lineWidth: .infinity,
            measure: truncating()
        )

        XCTAssertEqual(solution.frames.map(\.width), [205, 30])
        XCTAssertEqual(solution.size, CGSize(width: 239, height: 10))
    }

    func testNoItemsIsZeroSized() {
        let solution = solver.solve(idealSizes: [], lineWidth: 100, measure: truncating())

        XCTAssertEqual(solution.frames, [])
        XCTAssertEqual(solution.size, .zero)
    }
}
