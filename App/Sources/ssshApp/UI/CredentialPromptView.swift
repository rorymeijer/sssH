import SwiftUI
import ssshCore

/// Asks for a password, a key passphrase, or the answers to a
/// keyboard-interactive challenge.
///
/// One view for all three because a challenge is the general case: any number
/// of fields, each of which the server says whether to echo. The other two are
/// that with one field.
struct CredentialPromptView: View {
    let prompt: CredentialPromptCoordinator.PendingPrompt
    /// `nil` means cancelled.
    let respond: ([String]?, Bool) -> Void

    @State private var values: [String]
    @State private var remember = false
    @FocusState private var focusedField: Int?

    init(prompt: CredentialPromptCoordinator.PendingPrompt, respond: @escaping ([String]?, Bool) -> Void) {
        self.prompt = prompt
        self.respond = respond
        _values = State(initialValue: Array(repeating: "", count: prompt.fields.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(prompt.fields.enumerated()), id: \.element.id) { index, field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        // The server's echo flag decides this. A one-time code
                        // in a plain TextField is a code on a projector.
                        if field.echo {
                            TextField("", text: binding(for: index))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: index)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                        } else {
                            SecureField("", text: binding(for: index))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: index)
                        }
                    }
                }
            }

            if prompt.allowsRemembering {
                Toggle(isOn: $remember) {
                    Text("Bewaren in de sleutelhanger", comment: "Checkbox: store this secret in the Keychain")
                }
                .toggleStyle(.switch)
            }

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
                .disabled(!isComplete)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { focusedField = 0 }
        .accessibilityAddTraits(.isModal)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < values.count ? values[index] : "" },
            set: { newValue in
                guard index < values.count else { return }
                values[index] = newValue
            }
        )
    }

    /// Every field must be answered: RFC 4256 requires exactly one response per
    /// prompt, and a blank is a response the server may well accept.
    private var isComplete: Bool {
        values.count == prompt.fields.count && !values.contains(where: \.isEmpty)
    }

    private func submit() {
        guard isComplete else { return }
        respond(values, remember)
    }

    @ViewBuilder
    private var header: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                title.font(.headline)
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Server-written text. Selectable so it can be read and
                    // copied, never interpreted as markup.
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.tint)
        }
    }

    private var icon: String {
        switch prompt.kind {
        case .challenge: return "lock.shield"
        case .password, .passphrase: return "key.fill"
        }
    }

    private var title: Text {
        switch prompt.kind {
        case .password:
            return Text("Wachtwoord nodig", comment: "Title of the password prompt")
        case .passphrase:
            return Text("Wachtwoordzin nodig", comment: "Title of the key passphrase prompt")
        case .challenge(let name, _):
            return name.isEmpty
                ? Text("Extra verificatie nodig", comment: "Title of a keyboard-interactive prompt when the server gave no name")
                : Text(name)
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
        case .challenge(_, let instruction):
            return instruction.isEmpty
                ? Text("De server vraagt om aanvullende gegevens.",
                       comment: "Fallback when a keyboard-interactive challenge carries no instruction")
                : Text(instruction)
        }
    }
}
