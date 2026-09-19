import AppIntents
import SwiftData
import SwiftUI

@main
struct ssshApp: App {
    @State private var environment: AppEnvironment
    /// Set when the store could not be opened at all, so the app can say so
    /// rather than crash on launch.
    @State private var storeFailure: String?

    #if os(macOS)
    @State private var updater = SparkleUpdaterModel()
    #endif

    init() {
        let environment: AppEnvironment
        do {
            let container = try ModelContainerFactory.make()
            environment = AppEnvironment(modelContainer: container)
        } catch {
            // A CloudKit-backed store needs the iCloud entitlement, which a
            // build signed without a development team does not have. A local
            // store still keeps everything on this device, so try that before
            // giving up on persistence entirely.
            if let container = try? ModelContainerFactory.make(syncsConfiguration: false) {
                environment = AppEnvironment(modelContainer: container)
            } else {
                // Falling back to an in-memory store keeps the app usable for
                // the current session instead of refusing to launch; the
                // banner makes clear that nothing will be saved.
                environment = .ephemeral()
                _storeFailure = State(initialValue: error.localizedDescription)
            }
        }
        _environment = State(initialValue: environment)
        // Registered here, in `init`, because an intent can launch the app
        // cold: Siri or Shortcuts calls `perform()` before any view appears,
        // and an unregistered `@Dependency` is a fatalError, not a catchable
        // one.
        AppDependencyManager.shared.add(dependency: environment)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // The id lets the menu-bar item reopen this window after the last one
        // was closed; `openWindow` cannot address a group without one.
        WindowGroup(id: "main") {
            RootView(storeFailure: storeFailure)
                .environment(environment)
                .modelContainer(environment.modelContainer)
                // Drawn over everything, including any sheet: a lock that a
                // presented sheet sits on top of is not a lock.
                .overlay {
                    if environment.appLock.isLocked {
                        LockScreenView(lock: environment.appLock)
                    }
                }
                .task {
                    await environment.prepareSecurity()
                    // The "Verbind met <host>" phrase interpolates the host
                    // list, and Siri only knows the snapshot taken at the last
                    // extraction. Re-snapshot at launch so hosts added on
                    // another device (or last session) become speakable.
                    ssshShortcuts.updateAppShortcutParameters()
                    environment.publishWidgetSnapshot()
                }
                .onOpenURL { url in
                    environment.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        environment.appLock.applicationWillEnterForeground()
                    case .inactive, .background:
                        // `.inactive` as well as `.background`: on macOS that
                        // is what a hidden window reports, and the app
                        // switcher's snapshot is taken there too.
                        environment.appLock.applicationDidEnterBackground()
                        // Leaving the foreground is when "recent" can have
                        // changed — a session was opened — so the widget's
                        // snapshot refreshes here.
                        environment.publishWidgetSnapshot()
                    @unknown default:
                        environment.appLock.applicationDidEnterBackground()
                    }
                }
        }
        .commands {
            ssshCommands(environment: environment)
            #if os(macOS)
            UpdateCommands(updater: updater)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 700)
        // Several windows, each with its own tabs and splits. The session
        // layer is per window already — a `SessionManager` lives in the
        // environment, not in a singleton — so this costs nothing beyond
        // saying so.
        .windowResizability(.contentMinSize)
        #endif

        #if os(macOS)
        Settings {
            SecuritySettingsView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
        }

        Window(Text("Over sssH", comment: "Title of the about window"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarView(environment: environment)
                .modelContainer(environment.modelContainer)
        } label: {
            Image(systemName: "terminal")
                .accessibilityLabel(Text("sssH", comment: "Accessibility label of the menu bar item"))
        }
        #endif
    }
}

/// The menu bar, and the keyboard shortcuts that come with it.
///
/// Shortcuts chosen to match what a terminal user already has in their fingers
/// from iTerm and Terminal, because a terminal app that invents its own is one
/// people keep fighting:
///
/// | | |
/// |---|---|
/// | ⌘T, ⌘W, ⌘⇧W | new tab, close pane, close tab |
/// | ⌘D, ⌘⇧D | split right, split down |
/// | ⌘⌥[ ⌘⌥] | previous, next pane |
/// | ⌘⇧[ ⌘⇧] | previous, next tab |
/// | ⌘K | the palette, as in every editor written since 2015 |
/// | ⌘F | search this session |
/// | ⌘+ ⌘− ⌘0 | terminal text size |
///
/// The same shortcuts work on an iPad with a hardware keyboard, because
/// SwiftUI's `Commands` drive both.
struct ssshCommands: Commands {
    let environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if os(macOS)
        // Replacing the stock About panel: it can show a name and a version,
        // but not who made the app or where the source lives.
        CommandGroup(replacing: .appInfo) {
            Button {
                openWindow(id: "about")
            } label: {
                Text("Over sssH", comment: "Menu item that opens the about window")
            }
        }
        #endif

        CommandGroup(replacing: .newItem) {
            Button {
                environment.presentCommandPalette()
            } label: {
                Text("Ga naar…", comment: "Menu item: open the command palette")
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(replacing: .toolbar) {
            Button {
                environment.adjustTerminalFontSize(by: 1)
            } label: {
                Text("Groter", comment: "View menu: increase the terminal text size")
            }
            .keyboardShortcut("+", modifiers: .command)

            Button {
                environment.adjustTerminalFontSize(by: -1)
            } label: {
                Text("Kleiner", comment: "View menu: decrease the terminal text size")
            }
            .keyboardShortcut("-", modifiers: .command)

            Button {
                environment.resetTerminalFontSize()
            } label: {
                Text("Normale grootte", comment: "View menu: reset the terminal text size")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Toggle(isOn: blockInspectorBinding) {
                Text("Opdrachten", comment: "Menu item: toggle the command block list")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(environment.sessions.selectedTab == nil)
        }

        // Replacing rather than adding: the default Help menu opens an Apple
        // help book this app does not ship, so the item would beep and do
        // nothing.
        CommandGroup(replacing: .help) {
            Button {
                environment.showsHelp = true
            } label: {
                Text("sssH-handleiding", comment: "Help menu item that opens the in-app manual")
            }
            .keyboardShortcut("?", modifiers: .command)
        }

        CommandGroup(after: .appSettings) {
            Button {
                environment.appLock.lockNow()
            } label: {
                Text("Vergrendel sssH", comment: "Menu item that locks the app now")
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(!environment.appLock.canLock || !environment.security.isLockEnabled)
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

            Button {
                environment.sessions.showsServerMonitor = true
            } label: {
                Text("Serverstatus", comment: "Title of the server monitor panel")
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(environment.sessions.focusedSession == nil)

            Button {
                environment.sessions.showsSnippets = true
            } label: {
                Text("Fragmenten", comment: "Title of the snippet library")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(environment.sessions.focusedFeed == nil)

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
