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

/// Menu-bar commands. The full set, with customisable shortcuts, is Phase 8;
/// these are the ones a terminal app is unusable without.
struct ssshCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                environment.sessions.closeSelected()
            } label: {
                Text("Sluit sessie", comment: "Menu item: close the current session tab")
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(environment.sessions.selectedSession == nil)
        }
    }
}
