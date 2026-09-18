import Foundation
import XCTest
@testable import ssshCore

/// tmux's layout strings, which are what let sssh draw tmux's panes as its own
/// splits rather than as one terminal full of tmux's drawing.
///
/// The fixtures are real layout strings in tmux's documented format: a leaf is
/// `WxH,X,Y,<pane>`, `{…}` is left-to-right and `[…]` is top-to-bottom.
final class TmuxLayoutTests: XCTestCase {
    func testSinglePane() throws {
        let node = try TmuxLayoutParser.parse("bb62,178x45,0,0,1")

        XCTAssertEqual(node, .pane(
            TmuxLayoutGeometry(width: 178, height: 45, x: 0, y: 0),
            TmuxPaneID(rawValue: 1)
        ))
        XCTAssertEqual(node.panes, [TmuxPaneID(rawValue: 1)])
    }

    func testBracesAreSideBySide() throws {
        let node = try TmuxLayoutParser.parse("e6f3,178x45,0,0{88x45,0,0,1,89x45,89,0,2}")

        guard case .horizontal(let geometry, let children) = node else {
            return XCTFail("braces must mean a left-to-right split")
        }
        XCTAssertEqual(geometry.width, 178)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(node.panes, [TmuxPaneID(rawValue: 1), TmuxPaneID(rawValue: 2)])
    }

    func testBracketsAreStacked() throws {
        let node = try TmuxLayoutParser.parse("4a1c,178x45,0,0[178x22,0,0,1,178x22,0,23,2]")

        guard case .vertical = node else {
            return XCTFail("brackets must mean a top-to-bottom split")
        }
        XCTAssertEqual(node.panes, [TmuxPaneID(rawValue: 1), TmuxPaneID(rawValue: 2)])
    }

    func testNestedSplits() throws {
        // A pane on the left, two stacked on the right.
        let node = try TmuxLayoutParser.parse(
            "abcd,180x45,0,0{90x45,0,0,1,89x45,91,0[89x22,91,0,2,89x22,91,23,3]}"
        )

        XCTAssertEqual(node.panes, [
            TmuxPaneID(rawValue: 1),
            TmuxPaneID(rawValue: 2),
            TmuxPaneID(rawValue: 3),
        ])
    }

    func testThreeWaySplit() throws {
        // tmux writes an n-way split as one node with n children.
        let node = try TmuxLayoutParser.parse("1234,180x45,0,0{60x45,0,0,1,59x45,61,0,2,59x45,121,0,3}")

        guard case .horizontal(_, let children) = node else { return XCTFail("expected a split") }
        XCTAssertEqual(children.count, 3)
    }

    func testChecksumIsOptional() throws {
        let withChecksum = try TmuxLayoutParser.parse("bb62,178x45,0,0,1")
        let without = try TmuxLayoutParser.parse("178x45,0,0,1")
        XCTAssertEqual(withChecksum, without)
    }

    func testMalformedLayoutsAreRejected() {
        for layout in [
            "",
            "not a layout",
            "bb62,178x45,0,0{",                     // unterminated
            "bb62,178x45,0,0{88x45,0,0,1}",         // a split needs two children
            "bb62,178x45,0",                        // missing the y offset
            "bb62,178x45,0,0,1,trailing",           // trailing junk
        ] {
            XCTAssertThrowsError(try TmuxLayoutParser.parse(layout), layout)
        }
    }

    // MARK: - Conversion

    func testConvertsToASplitTreeWithTmuxsDividerPositions() throws {
        // A 60/40 split: the divider must land where tmux put it, or the panes
        // jump the moment tmux reports a layout.
        let node = try TmuxLayoutParser.parse("e6f3,100x45,0,0{60x45,0,0,1,39x45,61,0,2}")

        var identifiers: [TmuxPaneID: PaneID] = [:]
        let layout = node.asPaneLayout { tmuxPane in
            identifiers[tmuxPane, default: PaneID()]
        }

        guard case .split(let split) = layout else { return XCTFail("expected a split") }
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.fraction, 0.6, accuracy: 0.01)
    }

    func testThreeWaySplitNestsToTheRightWithProportionalDividers() throws {
        // PaneLayout is binary and tmux's is not, so a three-way split becomes
        // two nested ones. The second divider is a fraction of what is *left*,
        // not of the whole window — getting that wrong squashes the last pane.
        let node = try TmuxLayoutParser.parse("1234,120x45,0,0{60x45,0,0,1,30x45,61,0,2,29x45,92,0,3}")

        var identifiers: [TmuxPaneID: PaneID] = [:]
        let layout = node.asPaneLayout { tmuxPane in
            if let existing = identifiers[tmuxPane] { return existing }
            let new = PaneID()
            identifiers[tmuxPane] = new
            return new
        }

        XCTAssertEqual(layout.terminalCount, 3)

        guard case .split(let outer) = layout else { return XCTFail("expected a split") }
        XCTAssertEqual(outer.fraction, 0.5, accuracy: 0.01, "60 of 120")

        guard case .split(let inner) = outer.second else { return XCTFail("expected a nested split") }
        XCTAssertEqual(inner.fraction, 0.5, accuracy: 0.02, "30 of the 60 that are left")
    }

    func testPaneIdentityIsPreservedAcrossConversion() throws {
        // Terminals already on screen must keep their sessions when tmux
        // reports a new layout; they are matched by tmux's pane id.
        let node = try TmuxLayoutParser.parse("e6f3,100x45,0,0{60x45,0,0,7,39x45,61,0,9}")

        let seven = PaneID()
        let nine = PaneID()
        let layout = node.asPaneLayout { $0.rawValue == 7 ? seven : nine }

        XCTAssertEqual(layout.terminals, [seven, nine])
    }
}
