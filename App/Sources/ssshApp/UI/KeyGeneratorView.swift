import SwiftUI
import ssshCore
import ssshCrypto

/// Generates a key pair on this device.
///
/// The private half goes straight into the Keychain and is never shown. The
/// public half is shown, copyable, and is the only thing meant to leave —
/// which is the whole shape of the feature: you copy one line to a server, and
/// nothing you copy is worth stealing.
struct KeyGeneratorView: View {
    /// The host to attach the new key to, if any.
    let host: Host?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SSHKeyGenerator.Kind = .ed25519
    @State private var comment: String = ""
    @State private var passphrase: String = ""
    @State private var confirmation: String = ""
    @State private var isGenerating = false
    @State private var generated: SSHKeyGenerator.Generated?
    @State private var failure: String?
    @State private var didCopy = false

    private var passphrasesMatch: Bool {
        passphrase == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                if let generated {
                    result(generated)
                } else {
                    options
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Sleutel maken", comment: "Title of the key generator"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text("Annuleer", comment: "Cancel button")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if generated == nil {
                        Button {
                            Task { await generate() }
                        } label: {
                            Text("Maken", comment: "Button that generates the key")
                        }
                        .disabled(isGenerating || !passphrasesMatch)
                    } else {
                        Button { dismiss() } label: {
                            Text("Gereed", comment: "Button that closes the shell integration sheet")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private var options: some View {
        Section {
            Picker(selection: $kind) {
                Text("Ed25519", comment: "Key type: Ed25519").tag(SSHKeyGenerator.Kind.ed25519)
                Text("RSA 2048", comment: "Key type: 2048-bit RSA").tag(SSHKeyGenerator.Kind.rsa2048)
                Text("RSA 4096", comment: "Key type: 4096-bit RSA").tag(SSHKeyGenerator.Kind.rsa4096)
            } label: {
                Text("Soort", comment: "Sort files by kind")
            }
            .pickerStyle(.segmented)
        } footer: {
            kind == .ed25519
                ? Text("Ed25519 is korter, sneller en op elke server sinds 2014 bruikbaar. Kies dit tenzij je weet dat je RSA nodig hebt.",
                       comment: "Explains why Ed25519 is the default")
                : Text("RSA voor servers die nog geen Ed25519 aankunnen. Groter en langzamer, verder gelijkwaardig op deze lengtes.",
                       comment: "Explains when RSA is the right choice")
        }

        Section {
            TextField(text: $comment) {
                Text("Opmerking, bijvoorbeeld jij@laptop", comment: "Field label for the key comment")
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
        } footer: {
            Text("De opmerking staat achteraan de publieke sleutel en helpt je later terugvinden welke sleutel waar hoort.",
                 comment: "Explains what the key comment is for")
        }

        Section {
            SecureField(text: $passphrase) {
                Text("Wachtwoordzin, optioneel", comment: "Field label for an optional key passphrase")
            }
            SecureField(text: $confirmation) {
                Text("Nog een keer", comment: "Field label confirming the passphrase")
            }
            if !passphrasesMatch {
                Text("De wachtwoordzinnen zijn niet gelijk.",
                     comment: "Shown when the two passphrase fields differ")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("De privésleutel gaat hoe dan ook versleuteld in de sleutelhanger. Een wachtwoordzin beschermt het bestand áls je het exporteert.",
                 comment: "Explains that the passphrase protects an exported file, not the stored key")
        }

        if let failure {
            Section {
                Label {
                    Text(failure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func result(_ generated: SSHKeyGenerator.Generated) -> some View {
        Section {
            Text(verbatim: generated.publicLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            Button {
                Pasteboard.copy(generated.publicLine)
                didCopy = true
            } label: {
                Label {
                    didCopy
                        ? Text("Gekopieerd", comment: "Confirmation after copying the shell integration snippet")
                        : Text("Kopieer publieke sleutel", comment: "Button that copies the generated public key")
                } icon: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
            }
        } header: {
            Text("Publieke sleutel", comment: "Section header for the generated public key")
        } footer: {
            Text("Zet deze regel in ~/.ssh/authorized_keys op de server. De privésleutel staat in de sleutelhanger en wordt hier niet getoond.",
                 comment: "Tells the user what to do with the public key and that the private one is not shown")
        }

        if host != nil {
            Section {
                Label {
                    Text("Deze host gebruikt nu deze sleutel.",
                         comment: "Confirms the generated key was attached to the host")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundStyle(.green)
            }
        }
    }

    private func generate() async {
        isGenerating = true
        failure = nil
        defer { isGenerating = false }

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = passphrase.isEmpty ? nil : Array(passphrase.utf8)

        do {
            // Off the main actor: RSA 4096 takes seconds, and a spinning app
            // is how people conclude it crashed.
            let result = try await Task.detached(priority: .userInitiated) { [kind] in
                try SSHKeyGenerator.generate(kind: kind, comment: trimmedComment, passphrase: phrase)
            }.value

            let reference = SecretReference.makeUnique()
            try await environment.secretsStore.store(
                .privateKey(
                    openSSH: SecretString(result.armoredPrivateKey),
                    passphrase: phrase.map { SecretString(String(decoding: $0, as: UTF8.self)) }
                ),
                for: reference
            )

            if let host {
                host.secretReference = reference
                host.authenticationMethod = .privateKey
                host.updatedAt = Date()
            }

            generated = result
            // The passphrase has done its job; there is no reason for it to
            // stay in a view's state for the life of the sheet.
            passphrase = ""
            confirmation = ""
        } catch {
            failure = error.localizedDescription
        }
    }
}
