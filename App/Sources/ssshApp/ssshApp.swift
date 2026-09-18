import SwiftData
import SwiftUI

@main
struct ssshApp: App {
    @State private var environment: AppEnvironment
    /// Set when the store could not be opened at all, so the app can say so
    /// rather than crash on launch.
    @State private var storeFailure: String?

    init() {
        do {
            let container = try ModelContainerFactory.make()
            _environment = State(initialValue: AppEnvironment(modelContainer: container))
        } catch {
            // Falling back to an in-memory store keeps the app usable for the
            // current session instead of refusing to launch; the banner makes
            // clear that nothing will be saved.
            _environment = State(initialValue: .ephemeral())
            _storeFailure = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeFailure: storeFailure)
                .environment(environment)
                .modelContainer(environment.modelContainer)
        }
        .commands {
            ssshCommands(environment: environment)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}

/// The menu bar, and the keyboard shortcuts that come with it.
///
/// Shortcuts chosen to match what a terminal user already has in their fingers
/// from iTerm and Terminal, because a terminal app that invents its own is one
/// people keep fighting. Customisable bindings are Phase 8.
struct ssshCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                environment.presentCommandPalette()
            } label: {
                Text("Ga naar…", comment: "Menu item: open the command palette")
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandMenu(Text("Sessie", comment: "Menu title for session commands")) {
            Button {
                environment.sessions.splitFocusedPane(axis: .horizontal)
            } label: {
                Text("Splits naar rechts", comment: "Menu item: split the pane left-to-right")
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(environment.sessions.selectedTab == nil)

            Button {
                environment.sessions.splitFocusedPane(axis: .vertical)
            } label: {
                Text("Splits naar beneden", comment: "Menu item: split the pane top-to-bottom")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(environment.sessions.selectedTab == nil)

            Divider()

            Button {
                environment.sessions.selectedTab?.focusNextPane()
            } label: {
                Text("Volgend venster", comment: "Menu item: move focus to the next pane")
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(environment.sessions.selectedTab == nil)

            Button {
                environment.sessions.selectedTab?.focusPreviousPane()
            } label: {
                Text("Vorig venster", comment: "Menu item: move focus to the previous pane")
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(environment.sessions.selectedTab == nil)

            Divider()

            Toggle(isOn: broadcastBinding) {
                Text("Invoer naar alle vensters", comment: "Menu item: toggle broadcasting input to every pane")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(environment.sessions.selectedTab == nil)

            Toggle(isOn: blockInspectorBinding) {
                Text("Opdrachten", comment: "Menu item: toggle the command block list")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(environment.sessions.selectedTab == nil)

            Button {
                environment.showBlocksAndSearch()
            } label: {
                Text("Zoek in sessie…", comment: "Menu item: search the current session's commands and output")
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(environment.sessions.selectedTab == nil)

            Button {
                environment.sessions.showsFileBrowser = true
            } label: {
                Text("Bestanden", comment: "Title of the file browser")
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            // A tmux pane shares its connection with the other panes and has
            // no transport of its own, so there is nothing to open SFTP on.
            .disabled(environment.sessions.focusedSession == nil)

            Button {
                environment.sessions.showsTunnels = true
            } label: {
                Text("Tunnels", comment: "Section header: saved port forwards")
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(environment.sessions.focusedSession == nil)

            Divider()

            Button {
                environment.sessions.closeFocusedPane()
            } label: {
                Text("Sluit venster", comment: "Menu item: close the focused pane")
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(environment.sessions.selectedTab == nil)

            Button {
                environment.sessions.closeSelected()
            } label: {
                Text("Sluit sessie", comment: "Menu item: close the current session tab")
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(environment.sessions.selectedTab == nil)

            Divider()

            Button {
                environment.sessions.selectNextTab()
            } label: {
                Text("Volgende sessie", comment: "Menu item: switch to the next tab")
            }
            .keyboardShortcut("}", modifiers: [.command, .shift])

            Button {
                environment.sessions.selectPreviousTab()
            } label: {
                Text("Vorige sessie", comment: "Menu item: switch to the previous tab")
            }
            .keyboardShortcut("{", modifiers: [.command, .shift])
        }
    }

    /// Bound to the focused tab rather than to a stored flag, because broadcast
    /// is a property of one tab and must not leak to the next one selected.
    private var broadcastBinding: Binding<Bool> {
        Binding(
            get: { environment.sessions.selectedTab?.broadcastsInput ?? false },
            set: { environment.sessions.selectedTab?.broadcastsInput = $0 }
        )
    }

    /// The block list, unlike broadcast, is a way of working rather than a
    /// property of one connection, so it is bound to the window.
    private var blockInspectorBinding: Binding<Bool> {
        Binding(
            get: { environment.sessions.showsBlockInspector },
            set: { environment.sessions.showsBlockInspector = $0 }
        )
    }
}
