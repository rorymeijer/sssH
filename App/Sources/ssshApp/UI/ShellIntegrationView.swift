import SwiftUI
import ssshCore

/// Offers the shell-side snippet that makes command blocks exact.
///
/// It is a copy button and an instruction, not an installer. Writing to
/// someone's `.bashrc` over a session they opened for something else is an
/// edit to a machine they did not ask us to edit, and no amount of convenience
/// makes that acceptable in an SSH client.
struct ShellIntegrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shell: ShellIntegrationSnippet = .zsh
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("""
                         Zonder shell-integratie raadt sssh waar een opdracht begint en \
                         eindigt aan de hand van de regel die je shell teruggeeft. Dat werkt, \
                         maar de afsluitcode blijft onbekend en de grens klopt niet altijd.
                         """,
                         comment: "Explains what the fallback segmentation can and cannot do")

                    Text("""
                         Met onderstaande regels stuurt je shell zelf de standaardmarkeringen \
                         (OSC 133). Andere terminals lezen ze ook, dus je zit nergens aan vast.
                         """,
                         comment: "Explains that the snippet uses a standard other terminals also read")

                    Picker(selection: $shell) {
                        ForEach(ShellIntegrationSnippet.allCases) { option in
                            Text(verbatim: option.displayName).tag(option)
                        }
                    } label: {
                        Text("Shell", comment: "Label for the shell picker on the shell integration sheet")
                    }
                    .pickerStyle(.segmented)

                    Text("Zet dit onderaan \(shell.configurationFile) op de server.",
                         comment: "Instruction naming the shell's configuration file")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal) {
                        Text(verbatim: shell.script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        Pasteboard.copy(shell.script)
                        didCopy = true
                    } label: {
                        Label {
                            didCopy
                                ? Text("Gekopieerd", comment: "Confirmation after copying the shell integration snippet")
                                : Text("Kopieer naar klembord", comment: "Button that copies the shell integration snippet")
                        } icon: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("""
                         sssh past zelf niets aan op de server. Plak het er zelf in, zodat je \
                         ziet wat er verandert.
                         """,
                         comment: "States that sssh never edits the remote configuration itself")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("Shell-integratie", comment: "Title of the shell integration sheet"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
        }
        .onChange(of: shell) { _, _ in didCopy = false }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }
}
