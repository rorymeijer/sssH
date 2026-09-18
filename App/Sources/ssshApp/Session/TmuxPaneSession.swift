import Foundation
import Observation
import ssshCore

/// One pane of a tmux control-mode session, as a terminal feed.
///
/// Unlike a ``TerminalSession`` this owns no connection: every pane of a tmux
/// session shares one SSH channel, and the ``TmuxControlSession`` multiplexes
/// them. That is exactly why control mode is worth having — one connection,
/// any number of terminals, and the work survives a disconnect because it is
/// running on the server.
@MainActor
@Observable
final class TmuxPaneSession: TerminalFeed {
    let id = UUID()
    let paneID: TmuxPaneID
    let windowID: TmuxWindowID

    private(set) var remoteTitle: String?
    private(set) var windowName: String

    var title: String { remoteTitle ?? windowName }

    /// A tmux pane has no status of its own: if something is wrong it is wrong
    /// with the connection, and that banner belongs to the tab.
    var statusBanner: TerminalStatus { .none }

    private let output = PendingOutputBuffer()
    let blocks = SessionBlocks()
    private weak var controller: TmuxSessionController?

    init(paneID: TmuxPaneID, windowID: TmuxWindowID, windowName: String, controller: TmuxSessionController) {
        self.paneID = paneID
        self.windowID = windowID
        self.windowName = windowName
        self.controller = controller
    }

    func attachOutput(_ sink: @escaping ([UInt8]) -> Void) {
        output.attach(sink)
    }

    func detachOutput() {
        output.detach()
    }

    func deliver(_ bytes: [UInt8]) {
        blocks.consumeOutput(bytes)
        output.deliver(bytes)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        blocks.consumeInput(bytes)
        controller?.send(bytes, to: paneID)
    }

    func resize(columns: Int, rows: Int) {
        // tmux sizes a whole window, not a pane: the layout decides how that
        // space is divided. Resizing from the pane the user is dragging would
        // fight tmux's own layout engine.
        controller?.resize(window: windowID, columns: columns, rows: rows)
    }

    func updateRemoteTitle(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    func updateWindowName(_ name: String) {
        windowName = name
    }

    func close() async {
        blocks.finish()
        await controller?.killPane(paneID)
    }
}
