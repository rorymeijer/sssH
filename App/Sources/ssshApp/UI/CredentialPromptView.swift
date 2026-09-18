import SwiftUI
import ssshCore

/// Asks for a password or a key passphrase.
struct CredentialPromptView: View {
    let prompt: CredentialPromptCoordinator.PendingPrompt
    /// `nil` means cancelled.
    let respond: (String?, Bool) -> Void

    @State private var value = ""
    @State private var remember = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.headline)
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }

            SecureField(text: $value) {
                fieldLabel
            }
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(submit)

            Toggle(isOn: $remember) {
                Text("Bewaren in de sleutelhanger", comment: "Checkbox: store this secret in the Keychain")
            }
            .toggleStyle(.switch)

            HStack {
                Button(role: .cancel) {
                    respond(nil, false)
                } label: {
                    Text("Annuleer", comment: "Button: cancel the credential prompt")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: submit) {
                    Text("Verbind", comment: "Button: submit the credential and continue connecting")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(value.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { isFocused = true }
        .accessibilityAddTraits(.isModal)
    }

    private func submit() {
        guard !value.isEmpty else { return }
        respond(value, remember)
    }

    private var title: Text {
        switch prompt.kind {
        case .password:
            return Text("Wachtwoord nodig", comment: "Title of the password prompt")
        case .passphrase:
            return Text("Wachtwoordzin nodig", comment: "Title of the key passphrase prompt")
        }
    }

    private var subtitle: Text {
        switch prompt.kind {
        case .password(let username, let endpoint):
            return Text("Meld aan als \(username) op \(endpoint.description).",
                        comment: "Says which account on which host is being authenticated")
        case .passphrase(let keyLabel):
            return Text("De sleutel \(keyLabel) is beveiligd met een wachtwoordzin.",
                        comment: "Says which key file needs a passphrase")
        }
    }

    private var fieldLabel: Text {
        switch prompt.kind {
        case .password:
            return Text("Wachtwoord", comment: "Field label in the password prompt")
        case .passphrase:
            return Text("Wachtwoordzin", comment: "Field label in the passphrase prompt")
        }
    }
}
