import SwiftData
import SwiftUI
import ssshCore

/// Creates or edits a host.
///
/// Secrets are handled here and nowhere else in the UI: the key or password
/// goes straight to the Keychain and only an opaque reference is written to the
/// model. The form never displays a stored secret back — it says whether one
/// exists, which is all anyone needs to know.
struct HostEditorView: View {
    /// `nil` creates a new host.
    let host: Host?

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authenticationMethod: HostAuthenticationMethod = .askEveryTime
    @State private var password = ""
    @State private var privateKeyText = ""
    @State private var passphrase = ""
    @State private var startupCommand = ""
    @State private var tagText = ""
    @State private var usesTmux = false
    @State private var tmuxSessionName = "sssh"
    @State private var hasStoredSecret = false
    @State private var isSaving = false
    @State private var saveFailure: String?
    @State private var showsKeyGenerator = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) {
                        Text("Naam", comment: "Field label: the host's display name")
                    }
                    TextField(text: $hostname) {
                        Text("Adres", comment: "Field label: hostname or IP address")
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    TextField(text: $port) {
                        Text("Poort", comment: "Field label: TCP port")
                    }
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    TextField(text: $username) {
                        Text("Gebruikersnaam", comment: "Field label: the SSH username")
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                } header: {
                    Text("Verbinding", comment: "Section header: basic connection settings")
                }

                Section {
                    Picker(selection: $authenticationMethod) {
                        Text("Wachtwoord", comment: "Authentication method: password").tag(HostAuthenticationMethod.password)
                        Text("Sleutel", comment: "Authentication method: private key").tag(HostAuthenticationMethod.privateKey)
                        Text("Elke keer vragen", comment: "Authentication method: prompt on every connection").tag(HostAuthenticationMethod.askEveryTime)
                    } label: {
                        Text("Aanmelden met", comment: "Field label: how to authenticate")
                    }

                    switch authenticationMethod {
                    case .password:
                        SecureField(text: $password) {
                            Text("Wachtwoord", comment: "Field label: the password to store")
                        }
                        secretStatus

                    case .privateKey:
                        TextEditor(text: $privateKeyText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 120)
                            .accessibilityLabel(Text("Privésleutel", comment: "Accessibility label for the private key field"))
                        SecureField(text: $passphrase) {
                            Text("Wachtwoordzin (optioneel)", comment: "Field label: the passphrase protecting a private key")
                        }
                        Text("Laat de wachtwoordzin leeg om er elke keer om te worden gevraagd. Dat is veiliger.",
                             comment: "Explains that leaving the passphrase empty means being prompted each time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        secretStatus

                        if host != nil {
                            Button {
                                showsKeyGenerator = true
                            } label: {
                                Label {
                                    Text("Nieuwe sleutel maken…", comment: "Button that opens the key generator")
                                } icon: {
                                    Image(systemName: "key.horizontal")
                                }
                            }
                        }

                    case .askEveryTime:
                        Text("Er wordt niets bewaard. sssH vraagt bij elke verbinding om een wachtwoord.",
                             comment: "Explains that nothing is stored for this authentication method")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Aanmelden", comment: "Section header: authentication")
                } footer: {
                    // The claim has to match the setting. A footer that says
                    // "never leaves this device" while iCloud Keychain sync is
                    // on is worse than no footer.
                    appEnvironment.security.syncsSecrets
                        ? Text("Wachtwoorden en sleutels gaan via de iCloud-sleutelhanger naar je andere apparaten. Nooit via de gewone iCloud-database.",
                               comment: "Footer shown when secret sync is on")
                        : Text("Wachtwoorden en sleutels worden alleen in de sleutelhanger van dit apparaat bewaard, nooit in iCloud.",
                               comment: "Footer explaining that secrets stay in the device Keychain and are not synced")
                }

                Section {
                    TextField(text: $startupCommand) {
                        Text("Opdracht bij starten", comment: "Field label: a command run when the shell starts")
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    TextField(text: $tagText) {
                        Text("Labels, door komma's gescheiden", comment: "Field label: comma-separated tags")
                    }
                } header: {
                    Text("Overig", comment: "Section header: everything else")
                }

                Section {
                    Toggle(isOn: $usesTmux) {
                        Text("tmux gebruiken", comment: "Toggle: run tmux in control mode on connect")
                    }

                    if usesTmux {
                        TextField(text: $tmuxSessionName) {
                            Text("Naam van de tmux-sessie", comment: "Field label: the tmux session name to attach to")
                        }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    }
                } header: {
                    Text(verbatim: "tmux")
                } footer: {
                    Text("De vensters en deelvensters van tmux worden tabbladen en splitsingen in sssH, en je werk blijft draaien als de verbinding wegvalt.",
                         comment: "Footer explaining what tmux control mode does")
                }

                // Only on an existing host. A tunnel is a child record, and it
                // has nothing to belong to until the host has been saved once.
                if let host {
                    TunnelListEditor(host: host)
                }

                if let saveFailure {
                    Section {
                        Label {
                            Text(saveFailure)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $showsKeyGenerator) {
                KeyGeneratorView(host: host)
            }
            .navigationTitle(
                host == nil
                    ? Text("Nieuwe host", comment: "Title when adding a host")
                    : Text("Host bewerken", comment: "Title when editing a host")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Annuleer", comment: "Button: dismiss without saving")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text("Bewaar", comment: "Button: save the host")
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var secretStatus: some View {
        if hasStoredSecret {
            Label {
                Text("Er is al iets bewaard voor deze host. Laat het veld leeg om dat te houden.",
                     comment: "Shown when a secret already exists, explaining that leaving the field blank keeps it")
            } icon: {
                Image(systemName: "key.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(port).map { (1...65535).contains($0) } ?? false)
    }

    private func load() {
        guard let host else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authenticationMethod = host.authenticationMethod
        startupCommand = host.startupCommand ?? ""
        tagText = host.tags.joined(separator: ", ")
        usesTmux = host.usesTmuxControlMode
        tmuxSessionName = host.tmuxSessionName
        hasStoredSecret = host.secretReference != nil
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let target = host ?? Host()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.hostname = hostname.trimmingCharacters(in: .whitespaces)
        target.port = Int(port) ?? 22
        target.username = username.trimmingCharacters(in: .whitespaces)
        target.authenticationMethod = authenticationMethod
        target.startupCommand = startupCommand.isEmpty ? nil : startupCommand
        target.tags = tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        target.usesTmuxControlMode = usesTmux
        target.tmuxSessionName = tmuxSessionName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "sssh"
            : tmuxSessionName.trimmingCharacters(in: .whitespaces)
        target.updatedAt = Date()

        do {
            try await storeSecretIfNeeded(for: target)
        } catch {
            saveFailure = String(localized: "Het bewaren in de sleutelhanger is mislukt: \(error.localizedDescription)",
                                 comment: "Shown when writing a secret to the Keychain failed")
            return
        }

        if host == nil {
            modelContext.insert(target)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveFailure = String(localized: "Bewaren is mislukt: \(error.localizedDescription)",
                                 comment: "Shown when saving the host record failed")
        }
    }

    private func storeSecretIfNeeded(for target: Host) async throws {
        let secret: Secret?

        switch authenticationMethod {
        case .password:
            secret = password.isEmpty ? nil : .password(SecretString(password))
        case .privateKey:
            let key = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            secret = key.isEmpty ? nil : .privateKey(
                openSSH: SecretString(key),
                passphrase: passphrase.isEmpty ? nil : SecretString(passphrase)
            )
        case .askEveryTime:
            // Switching to "ask every time" means the stored secret should go:
            // leaving it behind would contradict what the setting says.
            if let reference = target.secretReference {
                try await appEnvironment.secretsStore.delete(reference)
                target.secretReference = nil
            }
            return
        }

        guard let secret else {
            // Nothing entered and something already stored: keep it. This is
            // what makes editing a host's name not wipe its password.
            return
        }

        let reference = target.secretReference ?? SecretReference.makeUnique()
        try await appEnvironment.secretsStore.store(secret, for: reference)
        target.secretReference = reference
    }
}
