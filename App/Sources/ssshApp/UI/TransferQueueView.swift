import SwiftUI
import ssshCore

/// The transfer queue, under the two panes.
///
/// Visible rather than hidden behind a badge: a transfer that failed silently
/// is how people find out a week later that half a backup never arrived.
struct TransferQueueView: View {
    let queue: TransferQueue
    /// Called when something finished, so the panes can pick up the new file.
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(queue.transfers) { transfer in
                    TransferRow(transfer: transfer) {
                        queue.cancel(transfer)
                    } retry: {
                        queue.retry(transfer)
                    }
                }
            }
            .listStyle(.inset)
        }
        .onChange(of: queue.transfers.filter { $0.state.isTerminal }.count) { _, _ in
            onChange()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Overdrachten", comment: "Toggle that shows the transfer queue")
                .font(.headline)

            if queue.activeCount > 0 {
                Text("\(queue.activeCount) bezig", comment: "How many transfers are still running or waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let rate = queue.currentRate {
                Text(verbatim: FileTransferText.formatRate(rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let remaining = queue.currentTimeRemaining {
                Text(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button { queue.cancelAll() } label: {
                Text("Alles annuleren", comment: "Button that cancels every queued transfer")
            }
            .disabled(queue.activeCount == 0)

            Button { queue.clearFinished() } label: {
                Text("Afgerond wissen", comment: "Button that clears finished transfers from the queue")
            }
            .disabled(!queue.hasFinishedItems)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(8)
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch transfer.state {
                case .running:
                    // Determinate only when the size is actually known. An
                    // invented total makes a bar that jumps backwards.
                    if let fraction = transfer.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                default:
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let total = transfer.totalBytes {
                Text(verbatim: "\(FileTransferText.formatBytes(transfer.transferredBytes)) / \(FileTransferText.formatBytes(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if transfer.state.isTerminal {
                if case .finished = transfer.state {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(action: retry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Opnieuw proberen", comment: "Button that retries a failed directory listing"))
                }
            } else {
                Button(action: cancel) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Annuleer", comment: "Cancel button"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusText: Text {
        switch transfer.state {
        case .waiting:
            return Text("In wachtrij", comment: "A transfer that has not started yet")
        case .running:
            return Text("Bezig", comment: "A transfer that is running")
        case .paused:
            return Text("Wacht op antwoord", comment: "A transfer paused for a collision decision")
        case .finished:
            return Text("Klaar", comment: "A transfer that finished successfully")
        case .cancelled:
            return Text("Geannuleerd.", comment: "A transfer was cancelled by the user")
        case .failed(let message):
            return Text(message)
        }
    }
}

/// Asked once per collision, and never resolved on the user's behalf.
///
/// Replace and keep-both both change what is on disk, and an SSH client that
/// picks one silently is an SSH client that eventually overwrites the wrong
/// file.
struct CollisionPromptView: View {
    let transfer: FileTransfer
    let resolve: (FileTransfer.CollisionPolicy) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Er bestaat al iets met deze naam", comment: "Title of the file collision prompt")
                .font(.headline)

            Text("\(destinationDescription) bestaat al.",
                 comment: "Says which path already exists")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button { finish(.replace) } label: {
                    Label {
                        Text("Vervangen", comment: "Collision option: overwrite the existing file")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                Button { finish(.keepBoth) } label: {
                    Label {
                        Text("Beide bewaren", comment: "Collision option: keep both files by renaming the new one")
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                Button { finish(.resume) } label: {
                    Label {
                        Text("Hervatten", comment: "Collision option: continue an interrupted transfer")
                    } icon: {
                        Image(systemName: "play")
                    }
                }
                Button(role: .cancel) { finish(.ask) } label: {
                    Label {
                        Text("Overslaan", comment: "Collision option: skip this file")
                    } icon: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .buttonStyle(.bordered)

            Text("Hervatten werkt alleen als het bestaande bestand korter is dan het origineel. Is het langer, dan is het een ander bestand en wordt er opnieuw begonnen.",
                 comment: "Explains when resuming applies")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private var destinationDescription: String {
        transfer.direction == .download ? transfer.localPath : transfer.remotePath
    }

    private func finish(_ policy: FileTransfer.CollisionPolicy) {
        resolve(policy)
        dismiss()
    }
}
