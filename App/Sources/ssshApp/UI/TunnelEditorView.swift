import SwiftUI
import SwiftData
import ssshCore

/// The tunnels saved on one host.
///
/// Editing a saved tunnel does not touch a running one. A tunnel is a listener
/// that exists on a connection, and changing the record under a live socket
/// would make the list say one thing while the machine does another; the
/// change takes effect the next time it starts, and the UI says so.
struct TunnelListEditor: View {
    @Bindable var host: Host
    @Environment(\.modelContext) private var modelContext
    @State private var editing: Tunnel?

    private var tunnels: [Tunnel] {
        (host.tunnels ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Section {
            ForEach(tunnels) { tunnel in
                Button {
                    editing = tunnel
                } label: {
                    TunnelSummaryRow(tunnel: tunnel)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        modelContext.delete(tunnel)
                    } label: {
                        Text("Verwijderen", comment: "Button that deletes the selected files")
                    }
                }
            }

            Button {
                let tunnel = Tunnel(name: "")
                tunnel.host = host
                modelContext.insert(tunnel)
                editing = tunnel
            } label: {
                Label {
                    Text("Tunnel toevoegen", comment: "Button that adds a saved port forward")
                } icon: {
                    Image(systemName: "plus")
                }
            }
        } header: {
            Text("Tunnels", comment: "Section header: saved port forwards")
        } footer: {
            Text("Een tunnel loopt over deze verbinding en stopt als die wegvalt. Tunnels die automatisch starten komen bij elke herverbinding terug.",
                 comment: "Footer explaining that tunnels live and die with the connection")
        }
        .sheet(item: $editing) { tunnel in
            TunnelEditorView(tunnel: tunnel)
        }
    }
}

private struct TunnelSummaryRow: View {
    let tunnel: Tunnel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tunnel.name.isEmpty ? tunnel.commandLineEquivalent : tunnel.name)
                    .lineLimit(1)
                if !tunnel.name.isEmpty {
                    Text(verbatim: tunnel.commandLineEquivalent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if tunnel.startsAutomatically {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Start automatisch", comment: "Toggle: start this tunnel when the host connects"))
            }

            if tunnel.isExposedToNetwork {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Bereikbaar vanaf het netwerk", comment: "Warning that a tunnel is not bound to loopback"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tunnel.kind {
        case .local: return "arrow.right.circle"
        case .remote: return "arrow.left.circle"
        case .dynamic: return "globe"
        }
    }
}

/// One tunnel.
struct TunnelEditorView: View {
    @Bindable var tunnel: Tunnel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $tunnel.name) {
                        Text("Naam", comment: "Placeholder for a new folder's name")
                    }

                    Picker(selection: Binding(get: { tunnel.kind }, set: { tunnel.kind = $0 })) {
                        Text("Lokaal (-L)", comment: "Tunnel kind: local forward").tag(TunnelKind.local)
                        Text("Extern (-R)", comment: "Tunnel kind: remote forward").tag(TunnelKind.remote)
                        Text("Dynamisch (-D)", comment: "Tunnel kind: dynamic SOCKS proxy").tag(TunnelKind.dynamic)
                    } label: {
                        Text("Soort", comment: "Sort files by kind")
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kindExplanation)
                }

                switch tunnel.kind {
                case .local:
                    localFields
                case .remote:
                    remoteFields
                case .dynamic:
                    dynamicFields
                }

                Section {
                    Toggle(isOn: $tunnel.startsAutomatically) {
                        Text("Start automatisch", comment: "Toggle: start this tunnel when the host connects")
                    }
                } footer: {
                    Text(verbatim: tunnel.commandLineEquivalent)
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle(Text("Tunnel", comment: "Title of the tunnel editor"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        tunnel.updatedAt = Date()
                        dismiss()
                    } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                    .disabled(!tunnel.isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var kindExplanation: Text {
        switch tunnel.kind {
        case .local:
            return Text("Iets op dit apparaat verbindt met een poort hier, en komt uit op de server.",
                        comment: "Explains what a local forward does")
        case .remote:
            return Text("Iets op de server verbindt met een poort daar, en komt uit op dit apparaat.",
                        comment: "Explains what a remote forward does")
        case .dynamic:
            return Text("Een SOCKS5-proxy op dit apparaat. De server maakt de verbindingen, dus het verkeer lijkt daarvandaan te komen.",
                        comment: "Explains what a dynamic forward does")
        }
    }

    @ViewBuilder
    private var localFields: some View {
        Section {
            listenFields
        } header: {
            Text("Luisteren op dit apparaat", comment: "Section header for the local listening address")
        }

        Section {
            TextField(text: $tunnel.remoteHost) {
                Text("Host", comment: "Placeholder for a tunnel's destination host")
            }
            PortField(label: Text("Poort", comment: "Label for a port number field"), port: $tunnel.remotePort)
        } header: {
            Text("Naartoe, gezien vanaf de server", comment: "Section header for a local forward's destination")
        } footer: {
            Text("Deze naam wordt op de server opgezocht, niet hier. Daarom werkt een adres dat alleen daar bestaat.",
                 comment: "Explains that the destination is resolved on the server")
        }
    }

    @ViewBuilder
    private var remoteFields: some View {
        Section {
            TextField(text: $tunnel.remoteBindAddress) {
                Text("Adres", comment: "Label for an address field")
            }
            PortField(label: Text("Poort", comment: "Label for a port number field"), port: $tunnel.remoteBindPort)
        } header: {
            Text("Luisteren op de server", comment: "Section header for a remote forward's listening address")
        } footer: {
            Text("De meeste servers laten alleen 127.0.0.1 toe, tenzij GatewayPorts aanstaat.",
                 comment: "Warns that most servers refuse a non-loopback remote bind")
        }

        Section {
            TextField(text: $tunnel.localHost) {
                Text("Host", comment: "Placeholder for a tunnel's destination host")
            }
            PortField(label: Text("Poort", comment: "Label for a port number field"), port: $tunnel.localPort)
        } header: {
            Text("Naartoe, op dit apparaat", comment: "Section header for a remote forward's local destination")
        }
    }

    @ViewBuilder
    private var dynamicFields: some View {
        Section {
            listenFields
        } header: {
            Text("Luisteren op dit apparaat", comment: "Section header for the local listening address")
        } footer: {
            Text("Stel deze poort in als SOCKS5-proxy in je browser of systeeminstellingen.",
                 comment: "Tells the user what to do with a dynamic forward's port")
        }
    }

    @ViewBuilder
    private var listenFields: some View {
        TextField(text: $tunnel.listenAddress) {
            Text("Adres", comment: "Label for an address field")
        }
        PortField(label: Text("Poort", comment: "Label for a port number field"), port: $tunnel.listenPort)

        if tunnel.isExposedToNetwork {
            // Said out loud rather than forbidden. It is occasionally exactly
            // what someone wants, and it is never what someone wants by
            // accident.
            Label {
                Text("Op dit adres is de tunnel bereikbaar vanaf het hele netwerk.",
                     comment: "Warning shown when a tunnel binds something other than loopback")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
            .font(.callout)
        }
    }
}

/// A port field that refuses to hold something that is not a port.
///
/// A plain number formatter allows 70 000 and negative numbers, and the failure
/// shows up as a tunnel that will not start with no explanation of why.
struct PortField: View {
    let label: Text
    @Binding var port: Int
    @State private var text: String = ""

    var body: some View {
        LabeledContent {
            TextField(text: $text) {
                label
            }
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .onAppear { text = port == 0 ? "" : String(port) }
            .onChange(of: text) { _, value in
                // An empty field means "let the system choose", which the
                // protocol spells 0.
                guard !value.isEmpty else { port = 0; return }
                guard let parsed = Int(value), (0...65_535).contains(parsed) else {
                    text = port == 0 ? "" : String(port)
                    return
                }
                port = parsed
            }
        } label: {
            label
        }
    }
}
