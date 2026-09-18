import Foundation

/// A tmux window layout, as described by the string in `%layout-change`.
///
/// The format is compact and recursive:
///
/// ```
/// bb62,178x45,0,0,1                    one pane
/// e6f3,178x45,0,0{88x45,0,0,1,89x45,89,0,2}    two panes side by side
/// 4a1c,178x45,0,0[178x22,0,0,1,178x22,0,23,2]  two panes stacked
/// ```
///
/// A leaf is `WxH,X,Y,<pane>`; `{…}` splits left-to-right and `[…]` splits
/// top-to-bottom. The four hex digits in front are tmux's checksum, which is
/// there to catch a layout string mangled in transit and is not needed to read
/// one.
///
/// This is what lets sssh show tmux's panes as its own splits rather than as
/// one terminal with tmux's own drawing in it.
public indirect enum TmuxLayoutNode: Hashable, Sendable {
    case pane(TmuxLayoutGeometry, TmuxPaneID)
    /// Children side by side. tmux writes this with braces.
    case horizontal(TmuxLayoutGeometry, [TmuxLayoutNode])
    /// Children stacked. tmux writes this with brackets.
    case vertical(TmuxLayoutGeometry, [TmuxLayoutNode])

    public var geometry: TmuxLayoutGeometry {
        switch self {
        case .pane(let geometry, _), .horizontal(let geometry, _), .vertical(let geometry, _):
            return geometry
        }
    }

    /// Every pane, in tmux's order — which is also the order they appear on
    /// screen, left to right and top to bottom.
    public var panes: [TmuxPaneID] {
        switch self {
        case .pane(_, let id):
            return [id]
        case .horizontal(_, let children), .vertical(_, let children):
            return children.flatMap(\.panes)
        }
    }
}

public struct TmuxLayoutGeometry: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int

    public init(width: Int, height: Int, x: Int, y: Int) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

public enum TmuxLayoutParser {
    public enum Failure: Error, Equatable {
        case malformed(String)
    }

    /// Parses a layout string, with or without its leading checksum.
    public static func parse(_ layout: String) throws -> TmuxLayoutNode {
        let trimmed = layout.trimmingCharacters(in: .whitespaces)
        var text = trimmed[...]

        // Strip the checksum: four hex digits and a comma, before the first
        // dimension. A layout may also arrive without one.
        if let comma = text.firstIndex(of: ","),
           text[..<comma].count == 4,
           text[..<comma].allSatisfy({ $0.isHexDigit }) {
            text = text[text.index(after: comma)...]
        }

        var scanner = Scanner(text)
        let node = try parseNode(&scanner)

        guard scanner.isAtEnd else {
            throw Failure.malformed("trailing characters after the layout")
        }
        return node
    }

    private static func parseNode(_ scanner: inout Scanner) throws -> TmuxLayoutNode {
        guard let width = scanner.takeInt() else { throw Failure.malformed("expected a width") }
        guard scanner.take("x") else { throw Failure.malformed("expected 'x' after the width") }
        guard let height = scanner.takeInt() else { throw Failure.malformed("expected a height") }
        guard scanner.take(",") else { throw Failure.malformed("expected ',' after the height") }
        guard let x = scanner.takeInt() else { throw Failure.malformed("expected an x offset") }
        guard scanner.take(",") else { throw Failure.malformed("expected ',' after the x offset") }
        guard let y = scanner.takeInt() else { throw Failure.malformed("expected a y offset") }

        let geometry = TmuxLayoutGeometry(width: width, height: height, x: x, y: y)

        if scanner.take("{") {
            let children = try parseChildren(&scanner, closing: "}")
            return .horizontal(geometry, children)
        }
        if scanner.take("[") {
            let children = try parseChildren(&scanner, closing: "]")
            return .vertical(geometry, children)
        }
        if scanner.take(",") {
            guard let pane = scanner.takeInt() else { throw Failure.malformed("expected a pane id") }
            return .pane(geometry, TmuxPaneID(rawValue: pane))
        }

        throw Failure.malformed("a node is neither a pane nor a split")
    }

    private static func parseChildren(_ scanner: inout Scanner, closing: Character) throws -> [TmuxLayoutNode] {
        var children: [TmuxLayoutNode] = []

        repeat {
            children.append(try parseNode(&scanner))
        } while scanner.take(",")

        guard scanner.take(closing) else {
            throw Failure.malformed("unterminated split")
        }
        // tmux never writes a split with one child, and treating one as a split
        // would produce a divider with nothing on one side of it.
        guard children.count >= 2 else {
            throw Failure.malformed("a split needs at least two children")
        }
        return children
    }

    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: Substring) {
            characters = Array(text)
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func take(_ expected: Character) -> Bool {
            guard index < characters.count, characters[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func takeInt() -> Int? {
            var digits = ""
            while index < characters.count, characters[index].isNumber {
                digits.append(characters[index])
                index += 1
            }
            return digits.isEmpty ? nil : Int(digits)
        }
    }
}

extension TmuxLayoutNode {
    /// Converts to sssh's own split tree.
    ///
    /// tmux allows a split with any number of children; ``PaneLayout`` is
    /// binary. The conversion nests to the right, with each divider placed
    /// where tmux put it, so the result looks the same even though the tree
    /// does not have the same shape.
    ///
    /// - Parameter paneID: maps a tmux pane to the identifier the app uses for
    ///   it, so the terminals already on screen keep their sessions.
    public func asPaneLayout(paneID: (TmuxPaneID) -> PaneID) -> PaneLayout {
        switch self {
        case .pane(_, let id):
            return .terminal(paneID(id))

        case .horizontal(let geometry, let children):
            return Self.nest(children, axis: .horizontal, total: geometry.width, paneID: paneID)

        case .vertical(let geometry, let children):
            return Self.nest(children, axis: .vertical, total: geometry.height, paneID: paneID)
        }
    }

    private static func nest(
        _ children: [TmuxLayoutNode],
        axis: PaneLayout.Axis,
        total: Int,
        paneID: (TmuxPaneID) -> PaneID
    ) -> PaneLayout {
        guard let first = children.first else {
            // Unreachable: the parser rejects a split with fewer than two
            // children. Returning something is still better than trapping on a
            // layout string from the network.
            return .terminal(paneID(TmuxPaneID(rawValue: 0)))
        }
        guard children.count > 1 else {
            return first.asPaneLayout(paneID: paneID)
        }

        let firstExtent = axis == .horizontal ? first.geometry.width : first.geometry.height
        let fraction = total > 0 ? Double(firstExtent) / Double(total) : 0.5

        return .split(PaneLayout.Split(
            id: PaneID(),
            axis: axis,
            fraction: min(max(fraction, PaneLayout.Split.minimumFraction), PaneLayout.Split.maximumFraction),
            first: first.asPaneLayout(paneID: paneID),
            second: nest(
                Array(children.dropFirst()),
                axis: axis,
                // The remaining children share what is left, so the next
                // divider is a fraction of that, not of the whole window.
                total: max(1, total - firstExtent),
                paneID: paneID
            )
        ))
    }
}
