import Foundation
import XCTest
@testable import ssshCore

/// Splitting and closing panes is where a layout tree quietly goes wrong:
/// a split that never collapses, a divider dragged to zero width, a pane that
/// is removed from the wrong branch. All of it is value-type logic, so all of
/// it is testable without a window.
final class PaneLayoutTests: XCTestCase {
    private let a = PaneID()
    private let b = PaneID()
    private let c = PaneID()
    private let d = PaneID()

    func testSingleTerminal() {
        let layout = PaneLayout.terminal(a)
        XCTAssertEqual(layout.terminals, [a])
        XCTAssertEqual(layout.terminalCount, 1)
        XCTAssertEqual(layout.id, a)
    }

    func testSplittingReplacesTheTargetInPlace() throws {
        let layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))

        XCTAssertEqual(layout.terminals, [a, b], "the original pane keeps its position")
        guard case .split(let split) = layout else { return XCTFail("expected a split") }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.fraction, 0.5)
    }

    func testSplittingDeepInTheTree() throws {
        var layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))
        layout = try XCTUnwrap(layout.splitting(b, with: c, axis: .vertical))
        layout = try XCTUnwrap(layout.splitting(c, with: d, axis: .horizontal))

        XCTAssertEqual(layout.terminals, [a, b, c, d], "reading order is preserved")
        XCTAssertEqual(layout.terminalCount, 4)
    }

    func testSplittingAnUnknownPaneDoesNothing() {
        // Distinguishable from "split the root", which is what a nil return is
        // for: the caller can look elsewhere instead of silently rearranging.
        XCTAssertNil(PaneLayout.terminal(a).splitting(b, with: c, axis: .horizontal))
    }

    func testRemovingCollapsesTheSplit() throws {
        let layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))

        let afterRemoval = try XCTUnwrap(layout.removing(b))
        XCTAssertEqual(afterRemoval, .terminal(a), "a split with one pane left is not a split")
    }

    func testRemovingTheLastPaneReportsEmpty() throws {
        // `.some(nil)` — found, and nothing is left. The tab closes rather than
        // becoming an empty frame.
        let result = try XCTUnwrap(PaneLayout.terminal(a).removing(a))
        XCTAssertNil(result)
    }

    func testRemovingAnUnknownPaneIsDistinctFromRemovingTheLast() {
        // The outer optional separates "not here" from "here, and now empty".
        // Collapsing the two would make closing a stale pane close the tab.
        XCTAssertNil(PaneLayout.terminal(a).removing(b))
    }

    func testRemovingFromANestedSplit() throws {
        var layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))
        layout = try XCTUnwrap(layout.splitting(b, with: c, axis: .vertical))
        XCTAssertEqual(layout.terminals, [a, b, c])

        let afterRemoval = try XCTUnwrap(try XCTUnwrap(layout.removing(b)))
        XCTAssertEqual(afterRemoval.terminals, [a, c])

        let afterSecond = try XCTUnwrap(try XCTUnwrap(afterRemoval.removing(c)))
        XCTAssertEqual(afterSecond, .terminal(a))
    }

    func testDividersAreClampedAwayFromTheEdges() throws {
        let layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))
        let splitID = layout.id

        guard case .split(let dragged) = layout.settingFraction(0, forSplit: splitID) else {
            return XCTFail("expected a split")
        }
        // A pane dragged to nothing cannot be dragged back.
        XCTAssertEqual(dragged.fraction, PaneLayout.Split.minimumFraction)

        guard case .split(let other) = layout.settingFraction(1.5, forSplit: splitID) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(other.fraction, PaneLayout.Split.maximumFraction)
    }

    func testSettingAFractionOnAnUnknownSplitIsANoOp() throws {
        let layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))
        XCTAssertEqual(layout.settingFraction(0.25, forSplit: PaneID()), layout)
    }

    func testCyclingThroughPanesWraps() throws {
        var layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .horizontal))
        layout = try XCTUnwrap(layout.splitting(b, with: c, axis: .vertical))

        XCTAssertEqual(layout.terminal(after: a), b)
        XCTAssertEqual(layout.terminal(after: c), a, "wraps to the start")
        XCTAssertEqual(layout.terminal(before: a), c, "wraps to the end")
        XCTAssertEqual(layout.terminal(before: b), a)
    }

    func testRoundTripsThroughCodable() throws {
        var layout = try XCTUnwrap(PaneLayout.terminal(a).splitting(a, with: b, axis: .vertical))
        layout = try XCTUnwrap(layout.splitting(b, with: c, axis: .horizontal))
        layout = layout.settingFraction(0.3, forSplit: layout.id)

        // Session restore stores this on disk, so the encoding has to survive a
        // round trip — including the indirect case.
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayout.self, from: data), layout)
    }
}
