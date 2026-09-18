import Foundation
import Observation

/// Samples the far machine over its own exec channels: uptime, load, memory,
/// disks.
///
/// One composite command per sample rather than one channel per figure —
/// servers limit concurrent channels, and the shell between the markers is
/// deliberately POSIX-plain. What a machine does not answer (no `/proc` on
/// macOS or BSD, no `df` in a container) is simply absent from the sample;
/// the view shows what came back and claims nothing about the rest.
@MainActor
@Observable
final class ServerMonitor {
    struct Sample {
        /// The `uptime` line as the server printed it.
        var uptime: String?
        /// 1, 5 and 15 minutes, parsed out of the uptime line.
        var loadAverages: [Double] = []
        var memoryUsedBytes: UInt64?
        var memoryTotalBytes: UInt64?
        var disks: [Disk] = []
        var takenAt: Date
    }

    struct Disk: Identifiable {
        var id: String { mountPoint }
        var mountPoint: String
        var usedBytes: UInt64
        var totalBytes: UInt64

        var fraction: Double {
            totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
        }
    }

    private(set) var sample: Sample?
    private(set) var failure: String?
    private(set) var isSampling = false

    private let session: TerminalSession

    init(session: TerminalSession) {
        self.session = session
    }

    /// Samples until cancelled. Meant for `.task`, which ties the loop's
    /// lifetime to the view showing the numbers — nothing polls a server
    /// nobody is looking at.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    func refresh() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        do {
            let marker = "~~sssh~~"
            let output = try await session.runCommand(
                "LANG=C uptime; echo '\(marker)'; cat /proc/meminfo 2>/dev/null; echo '\(marker)'; df -kP 2>/dev/null"
            )
            failure = nil
            sample = Self.parse(output, marker: marker)
        } catch {
            failure = ConnectionFailureText.describe(error)
        }
    }

    // MARK: - Parsing

    static func parse(_ output: String, marker: String) -> Sample {
        let sections = output.components(separatedBy: marker)
        var sample = Sample(takenAt: Date())

        if let uptimeSection = sections.first {
            let line = uptimeSection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                sample.uptime = line
                sample.loadAverages = parseLoadAverages(from: line)
            }
        }
        if sections.count > 1 {
            (sample.memoryUsedBytes, sample.memoryTotalBytes) = parseMeminfo(sections[1])
        }
        if sections.count > 2 {
            sample.disks = parseDF(sections[2])
        }
        return sample
    }

    /// `… load average: 0.52, 0.58, 0.59` — Linux says "load average:",
    /// macOS "load averages:" without commas. Taking the last three numbers
    /// on the line survives both.
    private static func parseLoadAverages(from line: String) -> [Double] {
        guard let range = line.range(of: "load average", options: .caseInsensitive) else { return [] }
        let tail = line[range.upperBound...]
        let numbers = tail
            .components(separatedBy: CharacterSet(charactersIn: " ,:"))
            .compactMap { Double($0) }
        return Array(numbers.suffix(3))
    }

    /// `/proc/meminfo` rows are `Name:   number kB`. Used is total minus
    /// `MemAvailable`, which is the kernel's own answer to "how much could a
    /// new process get" — free-plus-cache arithmetic gets containers wrong.
    private static func parseMeminfo(_ section: String) -> (used: UInt64?, total: UInt64?) {
        var values: [String: UInt64] = [:]
        for line in section.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let digits = parts[1].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
            guard let kb = UInt64(digits) else { continue }
            values[String(parts[0])] = kb * 1024
        }
        guard let total = values["MemTotal"], let available = values["MemAvailable"] else {
            return (nil, nil)
        }
        return (total >= available ? total - available : nil, total)
    }

    /// `df -kP`: `Filesystem 1024-blocks Used Available Capacity Mounted on`.
    /// Pseudo-filesystems are noise on every Linux box, so anything whose
    /// device does not look like a device is skipped.
    private static func parseDF(_ section: String) -> [Disk] {
        var disks: [Disk] = []
        for line in section.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 6,
                  let totalKB = UInt64(columns[1]),
                  let usedKB = UInt64(columns[2]),
                  totalKB > 0
            else { continue }

            let device = String(columns[0])
            // The mount point is everything after the capacity column, so a
            // path with spaces comes through whole.
            guard let capacityRange = line.range(of: String(columns[4])) else { continue }
            let mount = line[capacityRange.upperBound...].trimmingCharacters(in: .whitespaces)

            let pseudo = ["tmpfs", "devtmpfs", "devfs", "overlay", "udev", "shm", "none", "map"]
            guard !pseudo.contains(where: { device == $0 || device.hasPrefix("\($0):") }) else { continue }
            guard !mount.hasPrefix("/snap"), !mount.hasPrefix("/boot"), !mount.hasPrefix("/System/Volumes") || mount == "/System/Volumes/Data" else { continue }

            disks.append(Disk(mountPoint: mount, usedBytes: usedKB * 1024, totalBytes: totalKB * 1024))
        }
        // The interesting disks first; five is plenty for a status panel.
        return Array(disks.sorted { $0.totalBytes > $1.totalBytes }.prefix(5))
    }
}
