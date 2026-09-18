import Foundation
import ssshCore

/// Whatever is on the other end of a terminal view.
///
/// Two things are: a ``TerminalSession``, which owns an SSH channel, and a
/// ``TmuxPaneSession``, which is one pane of a tmux control-mode session and
/// shares its connection with the other panes. The terminal view and the split
/// layout do not care which, which is the point — without this, tmux panes
/// would have to be a parallel implementation of everything.
@MainActor
protocol TerminalFeed: AnyObject, Identifiable where ID == UUID {
    var title: String { get }
    /// What to show above the terminal, if anything.
    var statusBanner: TerminalStatus { get }
    /// The commands run in this pane, as blocks. Every feed has them: they are
    /// derived from the byte stream, not from anything only an SSH channel
    /// knows, so a tmux pane gets them on the same terms.
    var blocks: SessionBlocks { get }

    /// Called by the terminal view when it appears. Anything buffered before
    /// then is replayed, so a pane that connected off screen is not blank.
    func attachOutput(_ sink: @escaping ([UInt8]) -> Void)
    func detachOutput()

    func send(_ bytes: ArraySlice<UInt8>)
    func resize(columns: Int, rows: Int)
    func updateRemoteTitle(_ title: String)
    func close() async
}

/// What a pane has to say for itself.
enum TerminalStatus {
    case none
    case reconnecting(attempt: Int, retryingAt: Date?)
    case failed(String)
    case exited(SSHShellExit)
}

/// The buffer every feed needs: output that arrives before a view is attached.
///
/// A connection can come up before its view is on screen — a restored session,
/// a fast localhost connect, a tmux pane that already existed — and the login
/// banner and first prompt would otherwise be lost, leaving an apparently dead
/// terminal.
@MainActor
final class PendingOutputBuffer {
    private var sink: (([UInt8]) -> Void)?
    private var buffered: [UInt8] = []

    /// A runaway process writing to a detached pane must not grow this without
    /// bound, and the oldest output is the least useful by the time anyone
    /// looks.
    private let limit = 1 << 20

    func attach(_ sink: @escaping ([UInt8]) -> Void) {
        self.sink = sink
        guard !buffered.isEmpty else { return }
        let replay = buffered
        buffered.removeAll()
        sink(replay)
    }

    func detach() {
        sink = nil
    }

    func deliver(_ bytes: [UInt8]) {
        if let sink {
            sink(bytes)
            return
        }
        buffered.append(contentsOf: bytes)
        if buffered.count > limit {
            buffered.removeFirst(buffered.count - limit)
        }
    }
}
