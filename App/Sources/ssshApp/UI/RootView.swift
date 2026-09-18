import SwiftData
import SwiftUI
import ssshCore

/// The window: hosts on the left, open sessions on the right.
struct RootView: View {
    let storeFailure: String?

    @Environment(AppEnvironment.self) private var environment
    @State private var selectedHost: Host?
    @State private var hostBeingEdited: Host?
    @State private var isCreatingHost = false

    var body: some View {
        NavigationSplitView {
            HostListView(
                selection: $selectedHost,
                onConnect: { _ = environment.sessions.open($0) },
                onEdit: { hostBeingEdited = $0 },
                onCreate: { isCreatingHost = true }
            )
            .navigationTitle(Text("Hosts", comment: "Sidebar title: the list of saved hosts"))
        } detail: {
            SessionAreaView()
        }
        .overlay(alignment: .top) {
            if let storeFailure {
                StoreFailureBanner(message: storeFailure)
            }
        }
        .task {
            // Restore once the window exists, so a prompt from a restored
            // session has somewhere to appear.
            environment.restoreSessions()
        }
        .onChange(of: environment.sessions.tabs.count) { _, _ in
            environment.saveOpenSessions()
        }
        .onChange(of: environment.sessions.selectedTabID) { _, _ in
            environment.saveOpenSessions()
        }
        .sheet(item: $hostBeingEdited) { host in
            HostEditorView(host: host)
        }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil)
        }
        .sheet(item: hostKeyPromptBinding) { prompt in
            HostKeyPromptView(prompt: prompt) { decision in
                environment.hostKeyPrompts.answer(decision)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: paletteBinding) {
            CommandPaletteView(model: environment.palette)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: credentialPromptBinding) { prompt in
            CredentialPromptView(prompt: prompt) { values, remember in
                if let values {
                    environment.credentialPrompts.submit(values, remember: remember)
                } else {
                    environment.credentialPrompts.cancel()
                }
            }
            .interactiveDismissDisabled()
        }
    }

    /// Sheets driven by a coordinator rather than by local state: the prompt
    /// arrives from a network thread mid-handshake, and dismissing it has to
    /// deliver an answer rather than merely hide it — hence
    /// `interactiveDismissDisabled` and the explicit callbacks above.
    private var paletteBinding: Binding<Bool> {
        Binding(
            get: { environment.palette.isPresented },
            set: { if !$0 { environment.palette.dismiss() } }
        )
    }

    private var hostKeyPromptBinding: Binding<HostKeyPromptCoordinator.PendingPrompt?> {
        Binding(
            get: { environment.hostKeyPrompts.current },
            set: { if $0 == nil { environment.hostKeyPrompts.answer(.reject) } }
        )
    }

    private var credentialPromptBinding: Binding<CredentialPromptCoordinator.PendingPrompt?> {
        Binding(
            get: { environment.credentialPrompts.current },
            set: { if $0 == nil { environment.credentialPrompts.cancel() } }
        )
    }
}

/// Shown when the on-disk store could not be opened, so that "nothing I save is
/// being kept" is never a silent condition.
private struct StoreFailureBanner: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instellingen worden niet bewaard", comment: "Banner title when the database could not be opened")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
        .accessibilityElement(children: .combine)
    }
}
