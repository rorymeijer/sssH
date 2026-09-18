import Foundation
import Observation
import SwiftData
import ssshCore

/// One tab: a layout of terminals, and which of them has focus.
///
/// Two kinds of tab, and the difference is who owns the layout:
///
/// - **Direct.** sssh owns it. Splitting opens another SSH connection and
///   rearranges the tree here.
/// - **tmux.** tmux owns it. The layout is whatever tmux last reported, and
///   splitting asks tmux to split; the tree is a rendering of its answer. The
///   work then survives a disconnect, because it is running on the server.
///
/// Keeping both behind one type is what lets the split view, the tab strip and
/// the keyboard shortcuts stay unaware of the difference.
@MainActor
@Observable
final class TerminalTab: Identifiable {
    enum Mode {
        case direct
        case tmux(TmuxSessionController)
    }

    let id = UUID()
    private(set) var mode: Mode

    /// The layout when sssh owns it. In tmux mode the controller's is used.
    private var directLayout: PaneLayout
    private var directPanes: [PaneID: any TerminalFeed]

    var focusedPane: PaneID

    /// Sends typing to every pane in this tab at once.
    ///
    /// Off by default and per tab, not per window: broadcasting to panes the
    /// user cannot see is how people run `rm -rf` on the wrong machine.
    var broadcastsInput = false

    /// The host this tab was opened from, so a new pane can connect to the same
    /// place and so the tab can be restored.
    let hostID: PersistentIdentifier?

    init(session: TerminalSession, hostID: PersistentIdentifier?) {
        let pane = PaneID()
        self.mode = .direct
        self.directLayout = .terminal(pane)
        self.directPanes = [pane: session]
        self.focusedPane = pane
        self.hostID = hostID
    }

    init(tmux controller: TmuxSessionController, hostID: PersistentIdentifier?) {
        let pane = PaneID()
        self.mode = .tmux(controller)
        self.directLayout = .terminal(pane)
        self.directPanes = [:]
        self.focusedPane = pane
        self.hostID = hostID
    }

    // MARK: - Reading

    var layout: PaneLayout {
        switch mode {
        case .direct:
            return directLayout
        case .tmux(let controller):
            // Before tmux has reported anything there is nothing to draw. The
            // stored layout is a placeholder with no session behind it, which
            // renders as empty rather than as a broken terminal.
            return controller.layout ?? directLayout
        }
    }

    var panes: [PaneID: any TerminalFeed] {
        switch mode {
        case .direct:
            return directPanes
        case .tmux(let controller):
            guard let layout = controller.layout else { return [:] }
            // Match tmux's panes to the layout's identifiers by position: both
            // come from the same conversion, so the orders agree.
            let identifiers = layout.terminals
            let sessions = controller.panes
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map(\.value)
            return Dictionary(
                zip(identifiers, sessions).map { ($0, $1 as any TerminalFeed) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    var focusedSession: (any TerminalFeed)? {
        panes[focusedPane]
    }

    var sessions: [any TerminalFeed] {
        layout.terminals.compactMap { panes[$0] }
    }

    /// The title shown on the tab: the focused pane's, because that is the one
    /// being looked at.
    var title: String {
        focusedSession?.title ?? "sssh"
    }

    var paneCount: Int { layout.terminalCount }

    /// The connection state to show on the tab. In tmux mode every pane shares
    /// one connection, so the first pane's state speaks for all of them.
    var connectionState: SSHConnectionState {
        switch mode {
        case .direct:
            return (focusedSession as? TerminalSession)?.state ?? .idle
        case .tmux(let controller):
            return controller.hasEnded ? .disconnected(.remoteClosed) : .connected(.placeholder)
        }
    }

    // MARK: - Editing

    @discardableResult
    func split(_ target: PaneID, with session: TerminalSession, axis: PaneLayout.Axis) -> PaneID? {
        guard case .direct = mode else { return nil }

        let newPane = PaneID()
        guard let updated = directLayout.splitting(target, with: newPane, axis: axis) else { return nil }
        directLayout = updated
        directPanes[newPane] = session
        focusedPane = newPane
        return newPane
    }

    /// Asks tmux to split. The layout comes back through `%layout-change`
    /// rather than being applied here, because tmux decides where the divider
    /// goes.
    func requestTmuxSplit(axis: PaneLayout.Axis) {
        guard case .tmux(let controller) = mode,
              let pane = (focusedSession as? TmuxPaneSession)?.paneID
        else {
            return
        }
        controller.splitPane(pane, axis: axis)
    }

    /// Closes a pane.
    ///
    /// - Returns: `false` when that was the last pane, which the session
    ///   manager turns into closing the tab rather than leaving an empty frame.
    func closePane(_ target: PaneID) -> Bool {
        if case .tmux = mode {
            // tmux removes the pane and tells us; applying it here as well
            // would fight its layout.
            let closing = panes[target]
            Task { await closing?.close() }
            return paneCount > 1
        }

        guard let result = directLayout.removing(target) else { return true }

        let closing = directPanes[target]
        directPanes[target] = nil
        Task { await closing?.close() }

        guard let remaining = result else { return false }

        directLayout = remaining
        if focusedPane == target {
            focusedPane = remaining.terminals.first ?? focusedPane
        }
        return true
    }

    func setDivider(_ fraction: Double, forSplit split: PaneID) {
        guard case .direct = mode else { return }
        directLayout = directLayout.settingFraction(fraction, forSplit: split)
    }

    func focusNextPane() {
        guard let next = layout.terminal(after: focusedPane) else { return }
        focusedPane = next
    }

    func focusPreviousPane() {
        guard let previous = layout.terminal(before: focusedPane) else { return }
        focusedPane = previous
    }

    // MARK: - Input

    /// Routes typing from a pane, honouring broadcast.
    ///
    /// The pane that was typed into always receives its own input, even with
    /// broadcast on, so echo and cursor position stay right in the pane the
    /// user is looking at.
    func send(_ bytes: ArraySlice<UInt8>, from pane: PaneID) {
        guard broadcastsInput else {
            panes[pane]?.send(bytes)
            return
        }
        for session in sessions {
            session.send(bytes)
        }
    }

    func disconnectAll() async {
        if case .tmux(let controller) = mode {
            // Detach rather than kill: the session carries on server-side,
            // which is the point of running tmux at all.
            await controller.detach()
            await controller.stop()
            return
        }

        for session in sessions {
            await session.close()
        }
    }
}

extension SSHConnectionInfo {
    /// Stands in where a connection exists but its details belong to something
    /// else — a tmux session shared by every pane in a tab.
    static let placeholder = SSHConnectionInfo(
        endpoint: SSHEndpoint(hostname: ""),
        username: "",
        hostKey: SSHHostKey(algorithm: "", wireFormat: []),
        authenticatedWith: ""
    )
}
