import SwiftUI
import ssshCore

/// The detail side of the window: a tab strip and the panes under it.
struct SessionAreaView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var sessions = environment.sessions

        VStack(spacing: 0) {
            if !sessions.tabs.isEmpty {
                SessionTabStrip(
                    tabs: sessions.tabs,
                    selection: $sessions.selectedTabID,
                    onClose: { sessions.close($0) }
                )
                Divider()
            }

            if let tab = sessions.selectedTab {
                VStack(spacing: 0) {
                    if tab.broadcastsInput {
                        BroadcastBanner(paneCount: tab.paneCount) {
                            tab.broadcastsInput = false
                        }
                    }

                    PaneTreeView(tab: tab, layout: tab.layout)
                        // Rebuilding the terminal views when the tab changes
                        // would throw away the scrollback, so each tab keeps
                        // its own view identity.
                        .id(tab.id)
                        // `.inspector` rather than an `HStack`: on a Mac it is
                        // a resizable trailing column, on an iPhone it becomes
                        // a sheet. Hard-coding the column would leave a phone
                        // with two unusable halves.
                        .inspector(isPresented: $sessions.showsBlockInspector) {
                            if let feed = tab.focusedSession {
                                BlockInspector(feed: feed)
                                    // The list belongs to the pane, so
                                    // changing focus rebuilds it rather than
                                    // animating one pane's commands into
                                    // another's.
                                    .id(feed.id)
                                    .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
                            }
                        }
                }
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

/// Impossible to miss on purpose.
///
/// Broadcast means every keystroke goes to machines that are not on screen. The
/// failure mode is not cosmetic, so the banner is loud, permanent while it is
/// on, and one click from off.
private struct BroadcastBanner: View {
    let paneCount: Int
    let turnOff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Invoer gaat naar alle \(paneCount) vensters",
                 comment: "Banner shown while broadcast input is on, with the number of panes")
                .font(.callout.weight(.medium))

            Spacer(minLength: 0)

            Button(action: turnOff) {
                Text("Uitschakelen", comment: "Button that turns broadcast input off")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.22))
        .accessibilityElement(children: .combine)
    }
}

/// The tab strip. Horizontal scrolling rather than shrinking tabs to nothing,
/// because a tab whose label cannot be read is not a tab.
struct SessionTabStrip: View {
    let tabs: [TerminalTab]
    @Binding var selection: TerminalTab.ID?
    let onClose: (TerminalTab) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    SessionTabLabel(
                        tab: tab,
                        isSelected: tab.id == selection,
                        onSelect: { selection = tab.id },
                        onClose: { onClose(tab) }
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

private struct SessionTabLabel: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ConnectionStateDot(state: tab.connectionState)

            Text(tab.title)
                .lineLimit(1)
                .font(.callout)

            if tab.paneCount > 1 {
                Text(verbatim: "\(tab.paneCount)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(Text("\(tab.paneCount) vensters",
                                             comment: "Accessibility label for the pane count on a tab"))
            }

            if tab.broadcastsInput {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Invoer wordt uitgezonden",
                                             comment: "Accessibility label for the broadcast indicator on a tab"))
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Sluit \(tab.title)",
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
