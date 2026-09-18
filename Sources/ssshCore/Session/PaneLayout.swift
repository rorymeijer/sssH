import Foundation

/// The arrangement of terminals inside one tab.
///
/// A binary tree: a leaf is a terminal, a branch is a split with a divider
/// position. That is enough for every arrangement iTerm or tmux can make, and
/// it makes the operations people actually perform — split this pane, close
/// that one — local rather than a rearrangement of a grid.
///
/// A value type, so a layout can be diffed, restored from disk and undone
/// without any of it aliasing the live sessions. Panes refer to sessions by
/// identifier rather than holding them.
public enum PaneLayout: Hashable, Codable, Identifiable, Sendable {
    case terminal(PaneID)
    indirect case split(Split)

    public struct Split: Hashable, Codable, Sendable {
        public var id: PaneID
        public var axis: Axis
        /// Where the divider sits, as a fraction of the container. Clamped away
        /// from the edges so a pane can never be dragged to nothing — a pane
        /// with no area cannot be dragged back.
        public var fraction: Double
        public var first: PaneLayout
        public var second: PaneLayout

        public static let minimumFraction = 0.1
        public static let maximumFraction = 0.9
    }

    public enum Axis: String, Hashable, Codable, Sendable, CaseIterable {
        /// Panes side by side; the divider moves left and right.
        case horizontal
        /// Panes stacked; the divider moves up and down.
        case vertical
    }

    public var id: PaneID {
        switch self {
        case .terminal(let id): return id
        case .split(let split): return split.id
        }
    }

    /// Every terminal in the layout, left to right and top to bottom — which is
    /// also the order Tab moves through them.
    public var terminals: [PaneID] {
        switch self {
        case .terminal(let id):
            return [id]
        case .split(let split):
            return split.first.terminals + split.second.terminals
        }
    }

    public var terminalCount: Int { terminals.count }

    // MARK: - Editing

    /// Replaces the terminal `target` with a split of itself and `newPane`.
    ///
    /// - Returns: `nil` if `target` is not in this layout, so a caller can tell
    ///   "nothing happened" from "happened somewhere else".
    public func splitting(_ target: PaneID, with newPane: PaneID, axis: Axis) -> PaneLayout? {
        switch self {
        case .terminal(let id):
            guard id == target else { return nil }
            return .split(Split(
                id: PaneID(),
                axis: axis,
                fraction: 0.5,
                first: .terminal(id),
                second: .terminal(newPane)
            ))

        case .split(var split):
            if let updated = split.first.splitting(target, with: newPane, axis: axis) {
                split.first = updated
                return .split(split)
            }
            if let updated = split.second.splitting(target, with: newPane, axis: axis) {
                split.second = updated
                return .split(split)
            }
            return nil
        }
    }

    /// Removes a terminal, collapsing the split that held it.
    ///
    /// - Returns: the new layout, or `nil` when the whole layout was that one
    ///   terminal — which the caller turns into closing the tab rather than
    ///   leaving an empty one.
    public func removing(_ target: PaneID) -> PaneLayout?? {
        switch self {
        case .terminal(let id):
            // Double optional: `.some(nil)` means "found it, nothing is left",
            // `nil` means "not here". Collapsing those two would make removing
            // the last pane indistinguishable from removing a pane that does
            // not exist.
            return id == target ? .some(nil) : nil

        case .split(var split):
            if let result = split.first.removing(target) {
                guard let remaining = result else { return .some(split.second) }
                split.first = remaining
                return .some(.split(split))
            }
            if let result = split.second.removing(target) {
                guard let remaining = result else { return .some(split.first) }
                split.second = remaining
                return .some(.split(split))
            }
            return nil
        }
    }

    /// Moves a divider. Ignores an id that is not a split in this layout.
    public func settingFraction(_ fraction: Double, forSplit target: PaneID) -> PaneLayout {
        switch self {
        case .terminal:
            return self
        case .split(var split):
            if split.id == target {
                split.fraction = min(max(fraction, Split.minimumFraction), Split.maximumFraction)
                return .split(split)
            }
            split.first = split.first.settingFraction(fraction, forSplit: target)
            split.second = split.second.settingFraction(fraction, forSplit: target)
            return .split(split)
        }
    }

    /// The terminal after `current` in reading order, wrapping around.
    public func terminal(after current: PaneID) -> PaneID? {
        let panes = terminals
        guard let index = panes.firstIndex(of: current), !panes.isEmpty else { return panes.first }
        return panes[(index + 1) % panes.count]
    }

    public func terminal(before current: PaneID) -> PaneID? {
        let panes = terminals
        guard let index = panes.firstIndex(of: current), !panes.isEmpty else { return panes.last }
        return panes[(index - 1 + panes.count) % panes.count]
    }
}

/// Identifies a pane or a divider within a layout.
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}
