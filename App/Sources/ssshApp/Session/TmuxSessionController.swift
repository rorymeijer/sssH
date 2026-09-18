import Foundation
import Observation
import ssshCore

/// Keeps a tab's panes in step with a tmux control-mode session.
///
/// tmux owns the truth: which windows exist, which panes are in them, and how
/// they are arranged. This turns each `%layout-change` into a ``PaneLayout``
/// and each `%output` into bytes for the right terminal, and sends input back
/// the other way.
///
/// ## Panes keep their identity
///
/// When tmux reports a new layout, panes that were already there keep the same
/// ``TmuxPaneSession`` — matched on tmux's own pane id. Rebuilding them would
/// throw away the scrollback of every pane every time one was split.
@MainActor
@Observable
final class TmuxSessionController {
    /// Which tmux window this tab is showing. tmux windows map to tabs, so a
    /// controller follows one.
    private(set) var windowID: TmuxWindowID?
    private(set) var windows: [TmuxControlSession.Window] = []
    private(set) var panes: [TmuxPaneID: TmuxPaneSession] = [:]
    private(set) var layout: PaneLayout?
    private(set) var hasEnded = false
    private(set) var endReason: String?

    private var control: TmuxControlSession?
    private var paneIdentifiers: [TmuxPaneID: PaneID] = [:]
    private var updatesTask: Task<Void, Never>?

    init() {}

    /// Takes over a freshly opened channel.
    ///
    /// Called again after every reconnect, which is the case that matters: tmux
    /// reattaches, replays its layout, and the panes come back with their
    /// scrollback because they were never torn down.
    func attach(to shell: any SSHShellSession) {
        Task { await stopControl() }

        let control = TmuxControlSession(shell: shell)
        self.control = control
        hasEnded = false
        endReason = nil

        updatesTask = Task { [weak self] in
            guard let self else { return }
            await control.start()

            for await update in control.updates {
                await MainActor.run { self.handle(update) }
            }
        }
    }

    private func stopControl() async {
        updatesTask?.cancel()
        updatesTask = nil
        await control?.stop()
        control = nil
    }

    func stop() async {
        await stopControl()
    }

    /// Leaves tmux running server-side. The whole reason to use tmux.
    func detach() async {
        try? await control?.detach()
    }

    // MARK: - Updates from tmux

    private func handle(_ update: TmuxControlSession.Update) {
        switch update {
        case .output(let pane, let bytes):
            panes[pane]?.deliver(bytes)

        case .windowsChanged(let windows):
            self.windows = windows
            // Follow the active window unless the user has picked one.
            if windowID == nil {
                windowID = windows.first(where: \.isActive)?.id ?? windows.first?.id
            }
            applyLayout()

        case .layout(let window, _):
            guard window == windowID else { return }
            applyLayout()

        case .ended(let reason):
            hasEnded = true
            endReason = reason
        }
    }

    private func applyLayout() {
        guard let windowID,
              let window = windows.first(where: { $0.id == windowID }),
              let node = window.layout
        else {
            return
        }

        // Panes that survive keep their session and their scrollback; ones that
        // are gone are dropped.
        var survivors: [TmuxPaneID: TmuxPaneSession] = [:]
        for pane in node.panes {
            if let existing = panes[pane] {
                existing.updateWindowName(window.name)
                survivors[pane] = existing
            } else {
                survivors[pane] = TmuxPaneSession(
                    paneID: pane,
                    windowID: windowID,
                    windowName: window.name,
                    controller: self
                )
            }
        }
        panes = survivors

        layout = node.asPaneLayout { [weak self] tmuxPane in
            guard let self else { return PaneID() }
            if let existing = self.paneIdentifiers[tmuxPane] { return existing }
            let identifier = PaneID()
            self.paneIdentifiers[tmuxPane] = identifier
            return identifier
        }
    }

    func selectWindow(_ window: TmuxWindowID) {
        windowID = window
        applyLayout()
        Task { [control] in try? await control?.selectWindow(window) }
    }

    // MARK: - Acting

    func send(_ bytes: ArraySlice<UInt8>, to pane: TmuxPaneID) {
        let copy = Array(bytes)
        Task { [control] in try? await control?.send(copy[...], to: pane) }
    }

    func resize(window: TmuxWindowID, columns: Int, rows: Int) {
        Task { [control] in try? await control?.resize(window: window, columns: columns, rows: rows) }
    }

    func splitPane(_ pane: TmuxPaneID, axis: PaneLayout.Axis) {
        Task { [control] in try? await control?.splitPane(pane, axis: axis) }
    }

    func killPane(_ pane: TmuxPaneID) async {
        try? await control?.killPane(pane)
    }

    func newWindow() {
        Task { [control] in try? await control?.newWindow() }
    }
}
