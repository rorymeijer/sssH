import SwiftUI
import SwiftData
import ssshCore

/// The tunnels on the focused session: which are up, what they carry, and a
/// switch for each.
struct TunnelStatusView: View {
    let session: TerminalSession
    let host: Host?

    @Environment(\.dismiss) private var dismiss

    private var saved: [Tunnel] {
        (host?.tunnels ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if !session.tunnels.running.isEmpty {
                    Section {
                        ForEach(session.tunnels.running) { running in
                            RunningTunnelRow(running: running)
                        }
                    } header: {
                        Text("Actief", comment: "Section header for running tunnels")
                    }
                }

                Section {
                    if saved.isEmpty {
                        Text("Deze host heeft nog geen tunnels.",
                             comment: "Empty state in the tunnel panel")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(saved) { tunnel in
                            SavedTunnelRow(
                                tunnel: tunnel,
                                isRunning: session.tunnels.isRunning(tunnel),
                                failure: session.tunnels.failures[tunnel.persistentModelID]
                            ) {
                                Task { await session.tunnels.toggle(tunnel) }
                            } dismissFailure: {
                                session.tunnels.dismissFailure(tunnel.persistentModelID)
                            }
                        }
                    }
                } header: {
                    Text("Tunnels", comment: "Section header: saved port forwards")
                }
            }
            .navigationTitle(Text("Tunnels", comment: "Section header: saved port forwards"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}

private struct RunningTunnelRow: View {
    let running: TunnelController.Running

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text(verbatim: running.name)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if running.boundPort > 0 {
                    Text("poort \(running.boundPort)", comment: "Shows which port a tunnel actually bound")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Text(verbatim: running.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Active connections first: it is the number that says whether
                // the tunnel is doing anything right now, which is the usual
                // question.
                Text("\(running.statistics.activeConnections) actief",
                     comment: "How many connections are open through a tunnel")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(verbatim: "↑\(FileTransferText.formatBytes(running.statistics.bytesSent)) ↓\(FileTransferText.formatBytes(running.statistics.bytesReceived))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if running.isExposedToNetwork {
                Label {
                    Text("Bereikbaar vanaf het netwerk", comment: "Warning that a tunnel is not bound to loopback")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SavedTunnelRow: View {
    let tunnel: Tunnel
    let isRunning: Bool
    let failure: String?
    let toggle: () -> Void
    let dismissFailure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tunnel.name.isEmpty ? tunnel.commandLineEquivalent : tunnel.name)
                        .lineLimit(1)
                    Text(verbatim: tunnel.commandLineEquivalent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Toggle(isOn: Binding(get: { isRunning }, set: { _ in toggle() })) {
                    Text("Aan", comment: "Toggle that starts or stops a tunnel")
                }
                .labelsHidden()
                .disabled(!tunnel.isValid)
            }

            if !tunnel.isValid {
                Text("Deze tunnel is nog niet compleet.",
                     comment: "Shown on a saved tunnel that is missing a host or port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button(action: dismissFailure) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Melding sluiten", comment: "Accessibility label for dismissing a tunnel error"))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
