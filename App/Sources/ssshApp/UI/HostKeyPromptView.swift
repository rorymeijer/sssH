import SwiftUI
import ssshCore

/// Asks the user whether to trust a host key.
///
/// The two cases are presented very differently on purpose. A first connection
/// is routine and the sheet is calm about it. A *mismatch* is what a
/// man-in-the-middle looks like, so it is loud, it shows both fingerprints, and
/// trusting it takes a deliberate second action rather than the default button.
struct HostKeyPromptView: View {
    let prompt: HostKeyPromptCoordinator.PendingPrompt
    let respond: (SSHHostKeyDecision) -> Void

    @State private var hasAcknowledgedMismatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                FingerprintRow(
                    label: Text("Aangeboden sleutel", comment: "Label for the host key the server presented"),
                    algorithm: prompt.presentedKey.algorithm,
                    fingerprint: prompt.presentedKey.displayFingerprint,
                    isWarning: prompt.isMismatch
                )

                ForEach(Array(prompt.previouslyTrusted.enumerated()), id: \.offset) { _, key in
                    FingerprintRow(
                        label: Text("Eerder vertrouwd", comment: "Label for a host key that was trusted before"),
                        algorithm: key.algorithm,
                        fingerprint: key.displayFingerprint,
                        isWarning: false
                    )
                }
            }

            if prompt.isMismatch {
                Toggle(isOn: $hasAcknowledgedMismatch) {
                    Text("Ik weet waarom deze sleutel is veranderd",
                         comment: "Checkbox the user must tick before they can trust a changed host key")
                }
                .toggleStyle(.switch)
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var header: some View {
        if prompt.isMismatch {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("De hostsleutel van \(prompt.endpoint.description) is veranderd",
                         comment: "Title of the sheet shown when a host key does not match the stored one")
                        .font(.headline)
                    Text("Dit kan betekenen dat de server opnieuw is geïnstalleerd. Het kan ook betekenen dat iemand het verkeer onderschept. Verbind alleen als u weet welke van de twee het is.",
                         comment: "Explains the two reasons a host key changes and advises caution")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(.red)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Eerste verbinding met \(prompt.endpoint.description)",
                         comment: "Title of the sheet shown on a first connection to a host")
                        .font(.headline)
                    Text("sssh kent deze server nog niet. Controleer de vingerafdruk voordat u verbindt.",
                         comment: "Asks the user to verify the fingerprint on a first connection")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button(role: .cancel) {
                respond(.reject)
            } label: {
                Text("Verbind niet", comment: "Button: refuse the host key and abort the connection")
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                respond(.trustOnce)
            } label: {
                Text("Eenmalig verbinden", comment: "Button: accept the host key for this connection only")
            }
            .disabled(prompt.isMismatch && !hasAcknowledgedMismatch)

            Button {
                respond(.trustAndRemember)
            } label: {
                Text("Vertrouwen en onthouden", comment: "Button: accept the host key and store it")
            }
            .buttonStyle(.borderedProminent)
            .disabled(prompt.isMismatch && !hasAcknowledgedMismatch)
            // Enter accepts on a first connection, but never on a mismatch:
            // a security decision should not be reachable by reflex.
            .keyboardShortcut(prompt.isMismatch ? nil : .defaultAction)
        }
    }
}

private struct FingerprintRow: View {
    let label: Text
    let algorithm: String
    let fingerprint: String
    let isWarning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(algorithm)  \(fingerprint)")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}
