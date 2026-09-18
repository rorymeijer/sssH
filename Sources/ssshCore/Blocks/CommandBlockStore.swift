import Foundation

/// The blocks of one session, kept in order.
///
/// A plain value type so the whole thing can be tested without a UI, and so
/// the app's observable wrapper has nothing to do but hold one and forward to
/// it. Keeping the rules here rather than in the view is what stops the
/// eviction cap and the "unknown status is not success" rule from being
/// reimplemented slightly differently in three places.
public struct CommandBlockStore: Sendable {
    /// How many blocks to keep. A long-lived session must not grow without
    /// bound, and the oldest command is the one least likely to be wanted.
    public let capacity: Int

    public private(set) var blocks: [CommandBlock] = []
    /// Ids evicted by the cap, newest eviction last. The UI uses this to drop
    /// its own per-block state — a selection, an expanded flag — rather than
    /// leaking it for the life of the session.
    public private(set) var evicted: [UUID] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public mutating func apply(_ events: [CommandBlockEvent]) {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: CommandBlockEvent) {
        switch event {
        case .opened(let block):
            blocks.append(block)
            trim()
        case .commandChanged(let id, let command):
            mutate(id) { $0.command = command }
        case .stateChanged(let id, let state, let date):
            mutate(id) { block in
                block.state = state
                if case .finished = state { block.finishedAt = date }
            }
        case .outputAppended(let id, let bytes):
            mutate(id) { $0.output.append(contentsOf: bytes) }
        case .outputTruncated(let id):
            mutate(id) { $0.outputTruncated = true }
        }
    }

    public subscript(id: UUID) -> CommandBlock? {
        guard let index = index(of: id) else { return nil }
        return blocks[index]
    }

    /// Blocks matching a filter, oldest first — the order they are shown in.
    public func filtered(by filter: CommandBlockFilter) -> [CommandBlock] {
        guard filter.isActive else { return blocks }
        return blocks.filter(filter.matches)
    }

    public mutating func removeAll() {
        blocks.removeAll()
        evicted.removeAll()
    }

    /// Forget the eviction notices the UI has acted on.
    public mutating func clearEvictions() {
        evicted.removeAll()
    }

    /// Events almost always target the last block, so search from the end.
    private func index(of id: UUID) -> Int? {
        blocks.lastIndex { $0.id == id }
    }

    private mutating func mutate(_ id: UUID, _ body: (inout CommandBlock) -> Void) {
        guard let index = index(of: id) else { return }
        body(&blocks[index])
    }

    private mutating func trim() {
        guard blocks.count > capacity else { return }
        let excess = blocks.count - capacity
        evicted.append(contentsOf: blocks.prefix(excess).map(\.id))
        blocks.removeFirst(excess)
    }
}
