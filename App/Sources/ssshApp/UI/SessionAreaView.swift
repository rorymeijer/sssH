import SwiftUI
import ssshCore

/// The detail side of the window: a tab strip and the terminal under it.
struct SessionAreaView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var sessions = environment.sessions

        VStack(spacing: 0) {
            if !sessions.sessions.isEmpty {
                SessionTabStrip(
                    sessions: sessions.sessions,
                    selection: $sessions.selectedSessionID,
                    onClose: { sessions.close($0) }
                )
                Divider()
            }

            if let session = sessions.selectedSession {
                TerminalPane(session: session)
                    // Rebuilding the terminal view when the tab changes would
                    // throw away the scrollback, so each session keeps its own
                    // view identity.
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Geen sessie geopend", comment: "Empty state title when no session tab is open")
                    } icon: {
                        Image(systemName: "terminal")
                    }
                } description: {
                    Text("Kies een host in de zijbalk en verbind om te beginnen.",
                         comment: "Empty state body when no session tab is open")
                }
            }
        }
    }
}

/// The tab strip. Horizontal scrolling rather than shrinking tabs to nothing,
/// because a tab whose label cannot be read is not a tab.
struct SessionTabStrip: View {
    let sessions: [TerminalSession]
    @Binding var selection: TerminalSession.ID?
    let onClose: (TerminalSession) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: session.id == selection,
                        onSelect: { selection = session.id },
                        onClose: { onClose(session) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .accessibilityLabel(Text("Sessies", comment: "Accessibility label for the tab strip"))
    }
}

private struct SessionTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ConnectionStateDot(state: session.state)

            Text(session.title)
                .lineLimit(1)
                .font(.callout)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Sluit \(session.title)",
                                     comment: "Accessibility label for a tab's close button"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A coloured dot for the connection state.
///
/// Colour alone is never the signal: the state is also in the accessibility
/// label, and the shape changes for the states that matter.
struct ConnectionStateDot: View {
    let state: SSHConnectionState

    var body: some View {
        Group {
            switch state {
            case .connecting, .authenticating, .reconnecting:
                ProgressView()
                    .controlSize(.mini)
            case .connected:
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .disconnected(let reason):
                Image(systemName: reason.isUnexpected ? "exclamationmark.circle.fill" : "circle.fill")
                    .foregroundStyle(reason.isUnexpected ? .orange : .secondary)
            }
        }
        .font(.caption2)
        .accessibilityLabel(description)
    }

    private var description: Text {
        switch state {
        case .idle:
            return Text("Niet verbonden", comment: "Connection state: nothing attempted yet")
        case .connecting:
            return Text("Verbinden", comment: "Connection state: TCP connection in progress")
        case .authenticating:
            return Text("Aanmelden", comment: "Connection state: authenticating")
        case .connected:
            return Text("Verbonden", comment: "Connection state: connected")
        case .reconnecting(let attempt, _):
            return Text("Opnieuw verbinden, poging \(attempt)",
                        comment: "Connection state: retrying, with the attempt number")
        case .disconnected(let reason):
            return reason.isUnexpected
                ? Text("Verbinding verbroken", comment: "Connection state: dropped unexpectedly")
                : Text("Niet verbonden", comment: "Connection state: closed normally")
        }
    }
}
