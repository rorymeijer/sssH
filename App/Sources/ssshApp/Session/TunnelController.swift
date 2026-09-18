import Foundation
import Observation
import SwiftData
import ssshCore

/// The tunnels running on one session.
///
/// A tunnel outlives nothing: it belongs to the SSH connection underneath it,
/// and when that goes, so does the tunnel. That is why this is per session
/// rather than global, and why a reconnect restarts rather than resumes.
@MainActor
@Observable
final class TunnelController {
    /// One running tunnel, as the UI sees it.
    struct Running: Identifiable {
        let id: PersistentIdentifier
        var name: String
        var kind: TunnelKind
        var summary: String
        /// What was actually bound, which differs from what was asked for when
        /// the tunnel asked for port 0.
        var boundPort: Int
        var statistics: PortForwardStatistics
        var isExposedToNetwork: Bool
    }

    private(set) var running: [Running] = []
    /// Tunnels that would not start, and why. Kept until the user dismisses
    /// them: a tunnel that silently failed to come up is one people find out
    /// about by wondering why nothing works.
    private(set) var failures: [PersistentIdentifier: String] = [:]

    /// Unowned: the controller belongs to the session and never outlives it,
    /// and a strong reference here would be a cycle that keeps every closed
    /// session's connection alive.
    private unowned let session: TerminalSession
    private var active: [PersistentIdentifier: any ActivePortForward] = [:]
    /// What each running tunnel is called and where it goes, captured when it
    /// was started.
    ///
    /// Captured rather than looked up, because a tunnel can be deleted while
    /// it is running: the listener keeps working — a socket does not care that
    /// a record is gone — and it still has to be nameable so that it can be
    /// seen and stopped.
    private var descriptions: [PersistentIdentifier: Running] = [:]
    private var statisticsTask: Task<Void, Never>?

    init(session: TerminalSession) {
        self.session = session
    }

    func isRunning(_ tunnel: Tunnel) -> Bool {
        active[tunnel.persistentModelID] != nil
    }

    // MARK: - Starting and stopping

    func start(_ tunnel: Tunnel) async {
        let id = tunnel.persistentModelID
        guard active[id] == nil, tunnel.isValid else { return }
        failures[id] = nil

        let description = Running(
            id: id,
            name: tunnel.name.isEmpty ? tunnel.commandLineEquivalent : tunnel.name,
            kind: tunnel.kind,
            summary: tunnel.commandLineEquivalent,
            boundPort: 0,
            statistics: PortForwardStatistics(),
            isExposedToNetwork: tunnel.isExposedToNetwork
        )

        do {
            let service = try await session.portForwarding()
            let forward: any ActivePortForward
            switch tunnel.kind {
            case .local:
                forward = try await service.startLocalForward(tunnel.localForward)
            case .remote:
                forward = try await service.startRemoteForward(tunnel.remoteForward)
            case .dynamic:
                forward = try await service.startDynamicForward(tunnel.dynamicForward)
            }
            active[id] = forward
            descriptions[id] = description
            refresh()
            startPolling()
        } catch {
            failures[id] = TunnelFailureText.describe(error)
        }
    }

    func stop(_ tunnel: Tunnel) async {
        let id = tunnel.persistentModelID
        guard let forward = active.removeValue(forKey: id) else { return }
        descriptions[id] = nil
        await forward.stop()
        refresh()
    }

    func toggle(_ tunnel: Tunnel) async {
        if isRunning(tunnel) {
            await stop(tunnel)
        } else {
            await start(tunnel)
        }
    }

    func dismissFailure(_ id: PersistentIdentifier) {
        failures[id] = nil
    }

    /// Starts everything marked `startsAutomatically`.
    ///
    /// Called on every connection, including reconnections: the old tunnels
    /// died with the old connection, and the listeners have to be rebuilt on
    /// the new one.
    func startAutomaticTunnels(for host: Host) async {
        for tunnel in (host.tunnels ?? []) where tunnel.startsAutomatically {
            await start(tunnel)
        }
    }

    func stopAll() async {
        let forwards = active
        active.removeAll()
        descriptions.removeAll()
        for forward in forwards.values {
            await forward.stop()
        }
        statisticsTask?.cancel()
        statisticsTask = nil
        running = []
    }

    /// The connection went away, so every listener on it is already dead.
    ///
    /// Distinct from ``stopAll()``: there is nothing to ask the far side to
    /// cancel, and trying would hang on a socket that is gone.
    func connectionLost() {
        active.removeAll()
        descriptions.removeAll()
        statisticsTask?.cancel()
        statisticsTask = nil
        running = []
    }

    // MARK: - Live numbers

    private func startPolling() {
        guard statisticsTask == nil else { return }
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard !self.active.isEmpty else {
                    self.statisticsTask = nil
                    return
                }
                self.refreshStatistics()
            }
        }
    }

    /// Rebuilds the list. Called when tunnels come and go rather than on the
    /// timer, because the names and addresses come from the model and reading
    /// those every second would be pointless work.
    private func refresh() {
        running = active.compactMap { id, forward in
            guard var description = descriptions[id] else { return nil }
            description.boundPort = forward.boundPort
            description.statistics = forward.statistics
            return description
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if active.isEmpty {
            statisticsTask?.cancel()
            statisticsTask = nil
        }
    }

    private func refreshStatistics() {
        for index in running.indices {
            guard let forward = active[running[index].id] else { continue }
            running[index].statistics = forward.statistics
            running[index].boundPort = forward.boundPort
        }
    }

}
