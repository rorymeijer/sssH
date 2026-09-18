import Foundation

/// Where in a block a search hit landed.
public enum BlockSearchField: Hashable, Sendable {
    case command
    case output
}

public struct BlockSearchMatch: Identifiable, Sendable {
    public let id: UUID
    public let blockID: UUID
    public let field: BlockSearchField
    /// Line number within the field, counted from zero.
    public let lineNumber: Int
    /// The whole line the hit is on, so the UI can show it in context.
    public let line: String
    /// Where in `line` the query matched.
    public let range: Range<String.Index>

    public init(id: UUID = UUID(), blockID: UUID, field: BlockSearchField, lineNumber: Int, line: String, range: Range<String.Index>) {
        self.id = id
        self.blockID = blockID
        self.field = field
        self.lineNumber = lineNumber
        self.line = line
        self.range = range
    }
}

/// Searching a session, over blocks rather than over the raw scrollback.
///
/// This is the whole reason the block store exists in a terminal that already
/// has a scrollback: a hit in a flat buffer tells you a string is somewhere
/// above, while a hit in a block tells you which command produced it, whether
/// that command failed, and when. Jumping to the block is a more useful answer
/// than jumping to a line.
///
/// Searching happens entirely on device. Nothing is sent anywhere — there is
/// nowhere to send it to.
public enum BlockSearch {
    /// Case-insensitive unless the query contains an uppercase letter, which
    /// is the "smart case" rule from every editor people already use. Typing a
    /// capital is how you ask for a case-sensitive search; nobody wants a
    /// toggle for it.
    public static func isCaseSensitive(query: String) -> Bool {
        query.contains { $0.isUppercase }
    }

    public static func matches(
        in blocks: [CommandBlock],
        query: String,
        limit: Int = 500
    ) -> [BlockSearchMatch] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = isCaseSensitive(query: query) ? [.literal] : [.caseInsensitive, .literal]

        var results: [BlockSearchMatch] = []
        // Newest first: the thing you are looking for is almost always
        // something that just happened.
        for block in blocks.reversed() {
            if results.count >= limit { break }
            appendMatches(in: block.command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                          of: block, field: .command, query: query, options: options, limit: limit, into: &results)
            if results.count >= limit { break }
            appendMatches(in: block.outputLines,
                          of: block, field: .output, query: query, options: options, limit: limit, into: &results)
        }
        return results
    }

    private static func appendMatches(
        in lines: [String],
        of block: CommandBlock,
        field: BlockSearchField,
        query: String,
        options: String.CompareOptions,
        limit: Int,
        into results: inout [BlockSearchMatch]
    ) {
        for (number, line) in lines.enumerated() {
            guard results.count < limit else { return }
            var searchFrom = line.startIndex
            while searchFrom < line.endIndex,
                  let range = line.range(of: query, options: options, range: searchFrom..<line.endIndex) {
                results.append(BlockSearchMatch(blockID: block.id, field: field, lineNumber: number, line: line, range: range))
                guard results.count < limit else { return }
                // A zero-width match cannot happen with a non-empty literal
                // query, but advancing by at least one keeps this loop
                // obviously terminating.
                searchFrom = range.isEmpty ? line.index(after: range.lowerBound) : range.upperBound
            }
        }
    }
}

/// Which blocks to show. Kept here rather than in the view so the rule that
/// "no reported status is not success" is written once.
public struct CommandBlockFilter: Hashable, Sendable {
    public enum Outcome: String, Hashable, Sendable, CaseIterable {
        case all
        case failed
        case running
    }

    public var outcome: Outcome
    public var query: String

    public init(outcome: Outcome = .all, query: String = "") {
        self.outcome = outcome
        self.query = query
    }

    public var isActive: Bool { outcome != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ block: CommandBlock) -> Bool {
        switch outcome {
        case .all:
            break
        case .running:
            guard block.isRunning else { return false }
        case .failed:
            // Only a status the shell actually reported counts. A block with
            // no status is unknown, not successful, and must not be quietly
            // filtered out of a search for failures — but it must not be
            // claimed as a failure either.
            guard let status = block.exitStatus, status != 0 else { return false }
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let options: String.CompareOptions = BlockSearch.isCaseSensitive(query: trimmed)
            ? [.literal] : [.caseInsensitive, .literal]
        if block.command.range(of: trimmed, options: options) != nil { return true }
        return block.outputText.range(of: trimmed, options: options) != nil
    }
}
