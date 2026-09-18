import Foundation
import Observation
import ssshCore

/// The command blocks of one terminal feed, in the form SwiftUI observes.
///
/// A thin shell over ``CommandBlockSegmenter`` and ``CommandBlockStore``: the
/// rules live in `ssshCore` where they can be tested without a view, and this
/// exists to make the result observable and to keep the per-block UI state —
/// which block is selected, which are expanded — next to the blocks it belongs
/// to, so that eviction cleans both up together.
@MainActor
@Observable
final class SessionBlocks {
    private(set) var blocks: [CommandBlock] = []
    /// Which mode the segmenter settled on, so the UI can offer to install
    /// shell integration rather than silently producing worse blocks.
    private(set) var mode: CommandBlockSegmenter.Mode = .undetermined

    var filter = CommandBlockFilter()
    var selection: UUID?

    /// The search text.
    ///
    /// A computed property over ``filter`` rather than a `didSet` on it: the
    /// `@Observable` macro rewrites tracked stored properties into computed
    /// ones, and a property observer cannot survive that. Writing through here
    /// is what keeps the results in step with the query.
    var query: String {
        get { filter.query }
        set {
            guard newValue != filter.query else { return }
            filter.query = newValue
            scheduleSearch()
        }
    }

    /// Line-level hits for the current query, newest first. Separate from
    /// ``visibleBlocks``, which narrows the list: this says *where* inside a
    /// block the query matched, which is what makes stepping through results
    /// possible.
    private(set) var matches: [BlockSearchMatch] = []

    @ObservationIgnored private var segmenter = CommandBlockSegmenter()
    @ObservationIgnored private var store = CommandBlockStore()

    /// Reads the published array rather than the store: a computed property
    /// backed by `@ObservationIgnored` state would never invalidate a view.
    var visibleBlocks: [CommandBlock] {
        guard filter.isActive else { return blocks }
        return blocks.filter(filter.matches)
    }

    var hasShellIntegration: Bool { mode == .shellIntegration }

    func consumeOutput(_ bytes: [UInt8]) {
        apply(segmenter.consumeOutput(bytes[...]))
    }

    func consumeInput(_ bytes: ArraySlice<UInt8>) {
        apply(segmenter.consumeInput(bytes))
    }

    /// The shell exited or the connection dropped.
    func finish() {
        apply(segmenter.finish())
    }

    func block(_ id: UUID) -> CommandBlock? { blocks.last { $0.id == id } }

    func removeAll() {
        store.removeAll()
        blocks = []
        matches = []
        selection = nil
    }

    private func apply(_ events: [CommandBlockEvent]) {
        guard !events.isEmpty else { return }
        store.apply(events)
        if !store.evicted.isEmpty {
            if let selection, store.evicted.contains(selection) { self.selection = nil }
            store.clearEvictions()
        }
        // Assigning an unchanged value still counts as a mutation to
        // Observation, and this runs once per chunk of output.
        if mode != segmenter.mode { mode = segmenter.mode }

        // A block starting, finishing or being named is what the user is
        // watching for, so publish it — and re-run the search — at once.
        // Output arriving is neither: a command writing a megabyte would
        // otherwise rebuild the list, and re-scan the whole session, ten times
        // a second to change a preview line and a count nobody is reading yet.
        if events.contains(where: \.isStructural) {
            publish()
            scheduleSearch()
        } else {
            schedulePublish()
        }
    }

    /// A query of one character matches almost everything and costs a full
    /// scan to prove it; two is where the answer starts being worth having.
    private static let minimumQueryLength = 2

    private func scheduleSearch() {
        pendingSearch?.cancel()
        let query = filter.query.trimmingCharacters(in: .whitespaces)
        guard query.count >= Self.minimumQueryLength else {
            pendingSearch = nil
            matches = []
            return
        }
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.pendingSearch = nil
            self.matches = BlockSearch.matches(in: self.store.blocks, query: query, limit: 200)
        }
    }

    private func publish() {
        pendingPublish?.cancel()
        pendingPublish = nil
        blocks = store.blocks
    }

    private func schedulePublish() {
        guard pendingPublish == nil else { return }
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.pendingPublish = nil
            self.blocks = self.store.blocks
        }
    }

    @ObservationIgnored private var pendingPublish: Task<Void, Never>?
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
}

private extension CommandBlockEvent {
    /// True for the events that change the shape of the list rather than the
    /// contents of one block.
    var isStructural: Bool {
        switch self {
        case .opened, .stateChanged, .commandChanged: return true
        case .outputAppended, .outputTruncated: return false
        }
    }
}
