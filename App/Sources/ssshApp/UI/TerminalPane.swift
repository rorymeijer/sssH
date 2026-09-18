import SwiftUI
import ssshCore

/// A terminal, with whatever has to be said around it.
///
/// The failure banner sits above the terminal rather than replacing it: output
/// from before a drop is often the explanation for the drop, and hiding it to
/// show an error message throws that away.
struct TerminalPane: View {
    let session: any TerminalFeed
    let tab: TerminalTab
    let pane: PaneID

    @Environment(AppEnvironment.self) private var environment

    /// The profile for the host this pane is connected to, or nothing — in
    /// which case the terminal uses its own defaults rather than inventing a
    /// profile record.
    private var profile: TerminalProfile? {
        environment.sessions.host(for: tab)?.terminalProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            switch session.statusBanner {
            case .reconnecting(let attempt, let retryingAt):
                ReconnectingBanner(attempt: attempt, retryingAt: retryingAt)
            case .failed(let message):
                FailureBanner(message: message)
            case .exited(let exit):
                ExitBanner(exit: exit)
            case .none:
                EmptyView()
            }

            TerminalHostView(
                session: session,
                tab: tab,
                pane: pane,
                profile: profile,
                fontSizeAdjustment: environment.terminalFontSizeAdjustment
            )
            .accessibilityLabel(Text("Terminal voor \(session.title)",
                                     comment: "Accessibility label for the terminal view"))
            // A terminal is a grid of characters that changes under the
            // cursor, and VoiceOver has no good reading of one. The command
            // block list beside it is the accessible view of the same session:
            // real text, per command, with the outcome stated in words. This
            // hint points at it rather than pretending the grid is readable.
            .accessibilityHint(Text("Gebruik de lijst met opdrachten om de uitvoer als tekst te lezen.",
                                    comment: "Accessibility hint pointing VoiceOver users at the command block list"))
        }
    }
}

/// Shown while a dropped connection is being retried.
///
/// It counts down rather than spinning, because "when will this stop" is the
/// question people actually have, and it offers a way to retry now — waiting
/// out a 60-second backoff after plugging the network back in is maddening.
private struct ReconnectingBanner: View {
    let attempt: Int
    let retryingAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)

            if let retryingAt, retryingAt > Date() {
                Text("Verbinding verbroken. Nieuwe poging \(Text(retryingAt, style: .relative)).",
                     comment: "Reconnect banner with a countdown to the next attempt")
                    .font(.callout)
            } else {
                Text("Opnieuw verbinden, poging \(attempt)",
                     comment: "Connection state: retrying, with the attempt number")
                    .font(.callout)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }
}

private struct FailureBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }
}

private struct ExitBanner: View {
    let exit: SSHShellExit

    var body: some View {
        Label {
            if let signal = exit.signal {
                Text("De shell is gestopt door signaal \(signal).",
                     comment: "Shown when the remote shell was killed by a signal")
            } else {
                Text("De shell is gestopt met afsluitcode \(exit.status ?? -1).",
                     comment: "Shown when the remote shell exited with a non-zero status")
            }
        } icon: {
            Image(systemName: "power")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }
}
