import SwiftUI

/// Uptime, load, memory and disks for one connection.
///
/// Read-only on purpose: this panel answers "is that machine okay" at a
/// glance. Acting on the answer is what the terminal underneath it is for.
struct ServerMonitorView: View {
    @State private var monitor: ServerMonitor

    init(session: TerminalSession) {
        _monitor = State(initialValue: ServerMonitor(session: session))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Serverstatus", comment: "Title of the server monitor panel"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await monitor.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(Text("Vernieuwen", comment: "Accessibility label for the refresh button"))
                        .disabled(monitor.isSampling)
                    }
                }
        }
        // The sampling loop lives exactly as long as the panel: nothing polls
        // a server nobody is looking at.
        .task { await monitor.run() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let sample = monitor.sample {
            Form {
                systemSection(sample)
                memorySection(sample)
                disksSection(sample)

                Section {
                    if let failure = monitor.failure {
                        // A failed refresh with an older sample on screen:
                        // say the numbers are stale rather than hiding them.
                        Text("Vernieuwen mislukt: \(failure)", comment: "Shown under the server monitor when a refresh failed")
                            .foregroundStyle(.red)
                    }
                    Text("Gemeten om \(sample.takenAt, format: .dateTime.hour().minute().second())",
                         comment: "When the server monitor sample was taken")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else if let failure = monitor.failure {
            ContentUnavailableView {
                Label {
                    Text("Geen meting", comment: "Empty state title when the server monitor has no sample")
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                }
            } description: {
                Text(failure)
            } actions: {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Text("Opnieuw proberen", comment: "Button that retries a failed directory listing")
                }
            }
        } else {
            ProgressView {
                Text("Meten…", comment: "Shown while the first server monitor sample runs")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func systemSection(_ sample: ServerMonitor.Sample) -> some View {
        Section {
            if let uptime = sample.uptime {
                Text(verbatim: uptime)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if !sample.loadAverages.isEmpty {
                LabeledContent {
                    Text(verbatim: sample.loadAverages
                        .map { $0.formatted(.number.precision(.fractionLength(2))) }
                        .joined(separator: " · "))
                        .monospacedDigit()
                } label: {
                    Text("Belasting (1/5/15 min)", comment: "Label for the load averages row")
                }
            }
        } header: {
            Text("Systeem", comment: "Section header for uptime and load in the server monitor")
        }
    }

    @ViewBuilder
    private func memorySection(_ sample: ServerMonitor.Sample) -> some View {
        if let used = sample.memoryUsedBytes, let total = sample.memoryTotalBytes, total > 0 {
            Section {
                ProgressView(value: Double(used), total: Double(total)) {
                    Text("\(FileTransferText.formatBytes(used)) van \(FileTransferText.formatBytes(total)) in gebruik",
                         comment: "Memory usage row: used of total")
                        .font(.caption)
                }
            } header: {
                Text("Geheugen", comment: "Section header for memory in the server monitor")
            }
        }
    }

    @ViewBuilder
    private func disksSection(_ sample: ServerMonitor.Sample) -> some View {
        if !sample.disks.isEmpty {
            Section {
                ForEach(sample.disks) { disk in
                    ProgressView(value: disk.fraction) {
                        HStack {
                            Text(verbatim: disk.mountPoint)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(FileTransferText.formatBytes(disk.usedBytes)) van \(FileTransferText.formatBytes(disk.totalBytes)) in gebruik",
                                 comment: "Memory usage row: used of total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Schijven", comment: "Section header for disks in the server monitor")
            }
        }
    }
}
