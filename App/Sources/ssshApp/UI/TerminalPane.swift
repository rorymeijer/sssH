import SwiftUI
import ssshCore

/// A terminal, with whatever has to be said around it.
///
/// The failure banner sits above the terminal rather than replacing it: output
/// from before a drop is often the explanation for the drop, and hiding it to
/// show an error message throws that away.
struct TerminalPane: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            if let failure = session.failure {
                FailureBanner(message: failure)
            } else if let exit = session.exit, !exit.isSuccess {
                ExitBanner(exit: exit)
            }

            // Connecting starts when the session is opened, not here, so that
            // a host-key prompt has somewhere to belong before the terminal
            // appears.
            TerminalHostView(session: session, profile: nil)
                .accessibilityLabel(Text("Terminal voor \(session.title)",
                                         comment: "Accessibility label for the terminal view"))
        }
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
