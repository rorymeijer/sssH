import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ssshCore

/// Imports hosts from an OpenSSH config file.
///
/// The file is chosen by the user through the system picker rather than read
/// from `~/.ssh/config` directly: the app is sandboxed, and even where it is
/// not, going and reading someone's SSH directory uninvited is not a thing an
/// SSH client should do.
///
/// Nothing is imported until the user has seen what will be. The preview lists
/// every host, and every setting sssh will not honour, because an import that
/// silently drops half a host's configuration produces a saved connection that
/// behaves differently from the same alias in `ssh` — and the user finds that
/// out at the worst possible moment.
struct SSHConfigImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isPickingFile = false
    @State private var result: SSHConfigImport?
    @State private var selected: Set<String> = []
    @State private var importTunnels = true
    @State private var readFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    preview(result)
                } else {
                    picker
                }
            }
            .navigationTitle(Text("SSH-config importeren", comment: "Title of the ssh config import sheet"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text("Annuleer", comment: "Cancel button")
                    }
                }
                if let result {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            performImport(result)
                            dismiss()
                        } label: {
                            Text("Importeer \(selected.count)", comment: "Button that imports the selected hosts, with the count")
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.data, .text, .plainText]) { outcome in
            load(outcome)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private var picker: some View {
        ContentUnavailableView {
            Label {
                Text("Kies je SSH-config", comment: "Prompt to choose an ssh config file")
            } icon: {
                Image(systemName: "doc.text")
            }
        } description: {
            VStack(spacing: 10) {
                Text("Meestal ~/.ssh/config. sssH leest het bestand alleen; er wordt niets aan veranderd.",
                     comment: "Explains where the config lives and that sssh does not modify it")
                if let readFailure {
                    Text(readFailure)
                        .foregroundStyle(.red)
                }
            }
        } actions: {
            Button {
                isPickingFile = true
            } label: {
                Text("Bestand kiezen…", comment: "Button that opens the file picker")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func preview(_ result: SSHConfigImport) -> some View {
        List {
            Section {
                ForEach(result.hosts) { host in
                    ImportHostRow(host: host, isSelected: selected.contains(host.alias)) {
                        if selected.contains(host.alias) {
                            selected.remove(host.alias)
                        } else {
                            selected.insert(host.alias)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Hosts", comment: "Section header listing importable hosts")
                    Spacer()
                    Button {
                        selected = selected.count == result.hosts.count ? [] : Set(result.hosts.map(\.alias))
                    } label: {
                        selected.count == result.hosts.count
                            ? Text("Niets selecteren", comment: "Button that deselects every host")
                            : Text("Alles selecteren", comment: "Button that selects every host")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Section {
                Toggle(isOn: $importTunnels) {
                    Text("Tunnels meenemen", comment: "Toggle: also import LocalForward and friends")
                }
            }

            if !result.warnings.isEmpty {
                Section {
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                        ImportWarningRow(warning: warning)
                    }
                } header: {
                    Text("Niet overgenomen", comment: "Section header for settings that were not imported")
                }
            }
        }
    }

    private func load(_ outcome: Result<URL, Error>) {
        readFailure = nil
        switch outcome {
        case .failure(let error):
            readFailure = error.localizedDescription
        case .success(let url):
            // The picker hands back a security-scoped URL on both platforms,
            // and reading it without this fails for a file outside the app's
            // container — which `~/.ssh/config` always is.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = SSHConfigImporter.makeImport(from: SSHConfigParser.parse(text))
                result = parsed
                selected = Set(parsed.hosts.map(\.alias))
            } catch {
                readFailure = error.localizedDescription
            }
        }
    }

    private func performImport(_ result: SSHConfigImport) {
        let chosen = result.hosts.filter { selected.contains($0.alias) }
        var created: [String: Host] = [:]

        for importable in chosen {
            let host = Host(
                name: importable.alias,
                hostname: importable.hostname,
                port: importable.port ?? 22,
                username: importable.username ?? ""
            )
            host.keepAliveIntervalSeconds = importable.keepAliveIntervalSeconds ?? 30
            host.environment = importable.setEnvironment
            // Where the key was said to be, as a tag. The key itself is not
            // read: importing a config must not quietly load private keys off
            // disk, and the user attaches one deliberately.
            host.tags = importable.identityFiles.isEmpty ? [] : ["ssh-config"]
            modelContext.insert(host)
            created[importable.alias] = host

            if importTunnels {
                for tunnel in importable.tunnels {
                    modelContext.insert(makeTunnel(tunnel, for: host))
                }
            }
        }

        // Second pass: a ProxyJump can name a host that appears later in the
        // file, so the links are made once every host exists.
        for importable in chosen {
            guard let jumpAlias = importable.proxyJump,
                  let host = created[importable.alias],
                  let jumpHost = created[jumpAlias]
            else {
                continue
            }
            host.jumpHost = jumpHost
        }
    }

    private func makeTunnel(_ importable: ImportableTunnel, for host: Host) -> Tunnel {
        let tunnel: Tunnel
        switch importable.kind {
        case .local:
            tunnel = Tunnel(name: "", kind: .local)
            tunnel.listenAddress = importable.listenAddress
            tunnel.listenPort = importable.listenPort
            tunnel.remoteHost = importable.targetHost
            tunnel.remotePort = importable.targetPort
        case .remote:
            tunnel = Tunnel(name: "", kind: .remote)
            tunnel.remoteBindAddress = importable.listenAddress
            tunnel.remoteBindPort = importable.listenPort
            tunnel.localHost = importable.targetHost
            tunnel.localPort = importable.targetPort
        case .dynamic:
            tunnel = Tunnel(name: "", kind: .dynamic)
            tunnel.listenAddress = importable.listenAddress
            tunnel.listenPort = importable.listenPort
        }
        tunnel.host = host
        return tunnel
    }
}

private struct ImportHostRow: View {
    let host: ImportableHost
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // The selection is in the row's traits already; the circle would
            // read as a second announcement of the same thing.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: host.alias)
                Text(verbatim: summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !host.warnings.isEmpty {
                    Text("\(host.warnings.count) melding(en)",
                         comment: "How many warnings a host produced during import")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            if !host.tunnels.isEmpty {
                Text("\(host.tunnels.count) tunnel(s)", comment: "How many tunnels a host brings with it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var summary: String {
        var text = host.username.map { "\($0)@" } ?? ""
        text += host.hostname
        if let port = host.port, port != 22 { text += ":\(port)" }
        if let jump = host.proxyJump { text += " via \(jump)" }
        return text
    }
}

private struct ImportWarningRow: View {
    let warning: ImportWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                text
                if warning.line > 0 {
                    Text("regel \(warning.line)", comment: "Names the config file line a warning came from")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
    }

    private var text: Text {
        switch warning {
        case .proxyCommandNotSupported(let command, _):
            // Never run, and said plainly rather than hidden: it is an
            // arbitrary shell command out of a file.
            return Text("ProxyCommand wordt niet uitgevoerd: \(command). Gebruik ProxyJump.",
                        comment: "Explains that ProxyCommand is not run")
        case .matchNotEvaluated(let keyword, _):
            return Text("Match \(keyword) is overgeslagen: daarvoor zou sssH een opdracht moeten uitvoeren.",
                        comment: "Explains that a Match block was skipped")
        case .includeNotFollowed(let path, _):
            return Text("Include \(path) is niet gevolgd. Importeer dat bestand apart.",
                        comment: "Explains that Include was not followed")
        case .settingIgnored(let keyword, _, _):
            return Text("\(keyword) wordt door sssH niet gebruikt.",
                        comment: "Names a setting sssh has no equivalent for")
        case .malformedValue(let keyword, let value, _):
            return Text("\(keyword) begreep sssH niet: \(value)",
                        comment: "Names a setting whose value could not be read")
        case .unparsedLine(let text, _):
            return Text("Onbegrepen regel: \(text)",
                        comment: "Names a config line that could not be parsed at all")
        }
    }
}
