import Foundation

/// A tmux control-mode client.
///
/// Drives an ``SSHShellSession`` that is already running `tmux -CC`, and turns
/// it into something the UI can render as native tabs and splits: tmux windows
/// become tabs, tmux panes become terminals, and the layout string tmux sends
/// on every change becomes the split tree.
///
/// ## Why this is worth the trouble
///
/// Without it, tmux is a full-screen program drawing its own status bar and
/// dividers inside one terminal — scrollback belongs to tmux, the mouse is
/// tmux's, and copy and paste fight the app. With it, each tmux pane is a real
/// terminal view with real scrollback, and detaching and reattaching restores
/// the layout rather than redrawing it.
///
/// ## Command replies are matched by order, not by number
///
/// tmux numbers each command in its `%begin`/`%end` pair, but the numbering is
/// the server's and a client cannot predict where it starts. Replies do arrive
/// in the order the commands were sent, so a FIFO of continuations is both
/// simpler and harder to get wrong than trying to guess the numbering.
public actor TmuxControlSession {
    public enum Update: Sendable {
        case windowsChanged([Window])
        case layout(window: TmuxWindowID, node: TmuxLayoutNode)
        case output(pane: TmuxPaneID, bytes: [UInt8])
        case ended(reason: String?)
    }

    public struct Window: Hashable, Sendable, Identifiable {
        public var id: TmuxWindowID
        public var name: String
        public var isActive: Bool
        public var layout: TmuxLayoutNode?

        public var panes: [TmuxPaneID] { layout?.panes ?? [] }
    }

    public enum Failure: Error, Equatable {
        case notRunning
        case commandFailed([String])
    }

    private let shell: any SSHShellSession
    private var parser = TmuxControlParser()
    private var pendingCommands: [CheckedContinuation<[String], Error>] = []
    private var windows: [TmuxWindowID: Window] = [:]
    private var readTask: Task<Void, Never>?
    private var isRunning = false

    private var continuation: AsyncStream<Update>.Continuation?
    public nonisolated let updates: AsyncStream<Update>

    public init(shell: any SSHShellSession) {
        self.shell = shell
        var continuation: AsyncStream<Update>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Starts reading, and asks tmux what it currently has.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        readTask = Task { [weak self] in
            await self?.readLoop()
        }

        // The initial state, so the UI has something to draw before anything
        // changes.
        await refreshWindows()
    }

    public func stop() async {
        isRunning = false
        readTask?.cancel()
        readTask = nil
        failPendingCommands(Failure.notRunning)
        continuation?.finish()
    }

    // MARK: - Reading

    private func readLoop() async {
        do {
            for try await event in shell.events {
                guard isRunning else { return }

                switch event {
                case .output(let bytes), .errorOutput(let bytes):
                    for parsed in parser.consume(bytes) {
                        await handle(parsed)
                    }
                case .exit:
                    continuation?.yield(.ended(reason: nil))
                    isRunning = false
                    return
                }
            }
            continuation?.yield(.ended(reason: nil))
        } catch {
            continuation?.yield(.ended(reason: String(describing: error)))
        }
        isRunning = false
        failPendingCommands(Failure.notRunning)
    }

    private func handle(_ event: TmuxControlEvent) async {
        switch event {
        case .output(let pane, let bytes):
            continuation?.yield(.output(pane: pane, bytes: bytes))

        case .commandReply(_, let lines, let isError):
            guard !pendingCommands.isEmpty else { return }
            let continuation = pendingCommands.removeFirst()
            if isError {
                continuation.resume(throwing: Failure.commandFailed(lines))
            } else {
                continuation.resume(returning: lines)
            }

        case .layoutChanged(let window, let layout):
            if let node = try? TmuxLayoutParser.parse(layout) {
                windows[window]?.layout = node
                continuation?.yield(.layout(window: window, node: node))
                continuation?.yield(.windowsChanged(sortedWindows))
            }

        case .windowAdded, .windowClosed, .sessionsChanged, .sessionChanged:
            // Cheaper to ask tmux for the truth than to model every way the
            // window list can change.
            await refreshWindows()

        case .windowRenamed(let window, let name):
            windows[window]?.name = name
            continuation?.yield(.windowsChanged(sortedWindows))

        case .exited(let reason):
            continuation?.yield(.ended(reason: reason))
            isRunning = false

        case .clientDetached:
            continuation?.yield(.ended(reason: nil))
            isRunning = false

        case .paneModeChanged, .unhandled:
            break
        }
    }

    private var sortedWindows: [Window] {
        windows.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: - Commands

    /// Sends a command and waits for its reply.
    @discardableResult
    public func run(_ command: String) async throws -> [String] {
        guard isRunning else { throw Failure.notRunning }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands.append(continuation)

            Task {
                do {
                    try await shell.write(Array((command + "\n").utf8)[...])
                } catch {
                    // The write failed, so no reply is coming. Fail this
                    // command rather than leaving the FIFO desynchronised.
                    self.failOldestCommand(error)
                }
            }
        }
    }

    private func failOldestCommand(_ error: Error) {
        guard !pendingCommands.isEmpty else { return }
        pendingCommands.removeFirst().resume(throwing: error)
    }

    private func failPendingCommands(_ error: Error) {
        let pending = pendingCommands
        pendingCommands.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }

    /// Asks tmux for its current windows and layouts.
    public func refreshWindows() async {
        let format = "#{window_id}\t#{window_name}\t#{window_active}\t#{window_layout}"
        guard let lines = try? await run("list-windows -F \"\(format)\"") else { return }

        var updated: [TmuxWindowID: Window] = [:]
        for line in lines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4,
                  let id = TmuxControlParser.windowID(fields[0])
            else {
                continue
            }
            updated[id] = Window(
                id: id,
                name: fields[1],
                isActive: fields[2] == "1",
                layout: try? TmuxLayoutParser.parse(fields[3])
            )
        }

        windows = updated
        continuation?.yield(.windowsChanged(sortedWindows))
    }

    // MARK: - Acting on panes

    /// Sends bytes to a pane.
    ///
    /// `send-keys -H` takes hex, which is the only way to put an arbitrary byte
    /// through: tmux's other forms interpret key names, so a literal `Enter`
    /// typed into a text editor would become a newline.
    public func send(_ bytes: ArraySlice<UInt8>, to pane: TmuxPaneID) async throws {
        guard !bytes.isEmpty else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        try await run("send-keys -t \(pane) -H \(hex)")
    }

    public func resize(window: TmuxWindowID, columns: Int, rows: Int) async throws {
        try await run("resize-window -t \(window) -x \(max(1, columns)) -y \(max(1, rows))")
    }

    public func selectWindow(_ window: TmuxWindowID) async throws {
        try await run("select-window -t \(window)")
    }

    public func newWindow() async throws {
        try await run("new-window")
    }

    public func splitPane(_ pane: TmuxPaneID, axis: PaneLayout.Axis) async throws {
        // tmux's flags read backwards from how the split looks: `-h` puts the
        // new pane to the *right*, which is a left-to-right split.
        let flag = axis == .horizontal ? "-h" : "-v"
        try await run("split-window \(flag) -t \(pane)")
    }

    public func killPane(_ pane: TmuxPaneID) async throws {
        try await run("kill-pane -t \(pane)")
    }

    /// Leaves control mode without killing the session, so the work carries on
    /// server-side and can be reattached later. This is the whole point of
    /// running tmux.
    public func detach() async throws {
        try await run("detach-client")
    }
}
