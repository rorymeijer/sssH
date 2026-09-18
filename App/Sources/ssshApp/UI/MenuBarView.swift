#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

/// The menu-bar item: connect to a recent host without the main window.
///
/// Deliberately small. The menu bar is for the two-second path — "get me a
/// terminal on that machine" — and everything else (tunnels, files, snippets)
/// needs a session in front of you anyway, which means the main window.
struct MenuBarView: View {
    let environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @Query(sort: [SortDescriptor(\Host.lastConnectedAt, order: .reverse)])
    private var hosts: [Host]

    var body: some View {
        let connectable = hosts.filter(\.isConnectable).prefix(8)

        if connectable.isEmpty {
            Text("Geen opgeslagen hosts", comment: "Menu bar item shown when there are no connectable hosts")
        } else {
            ForEach(Array(connectable)) { host in
                Button {
                    activate()
                    environment.sessions.open(host)
                } label: {
                    Text(verbatim: host.displayName)
                }
            }
        }

        Divider()

        Button {
            activate()
        } label: {
            Text("Open sssH", comment: "Menu bar item that brings the app forward")
        }
    }

    /// Brings the app forward, recreating the main window when every window
    /// was closed — activating an app with no windows shows nothing.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            openWindow(id: "main")
        }
    }
}
#endif
