import Foundation
import SwiftData
import ssshCore

/// A saved port forward.
///
/// Every property has a default and nothing is uniquely constrained, for the
/// same reason as ``Host``: CloudKit's private database refuses anything else,
/// and designing to that now avoids a migration on everyone's device in
/// Phase 7.
///
/// Nothing here is a secret. A tunnel is a pair of addresses; what makes it
/// privileged is the SSH connection it runs over, and that is the host's
/// business, not this record's.
@Model
final class Tunnel {
    var name: String = ""
    var kindRaw: String = TunnelKind.local.rawValue

    /// Which local interface to bind, for `-L` and `-D`.
    ///
    /// `127.0.0.1` rather than `0.0.0.0`, always, unless the user changes it.
    /// The difference is whether the tunnel is available to the machine or to
    /// the whole network, and defaulting to the network is how a personal
    /// tunnel becomes an open relay on a café Wi-Fi.
    var listenAddress: String = "127.0.0.1"
    /// `0` asks the operating system to pick, reported back once it is up.
    var listenPort: Int = 0

    /// For `-L`: the destination as seen from the SSH server. Unused by `-D`,
    /// where every connection carries its own.
    var remoteHost: String = ""
    var remotePort: Int = 0

    /// For `-R`: what the server binds, and where connections come back to.
    var remoteBindAddress: String = "127.0.0.1"
    var remoteBindPort: Int = 0
    var localHost: String = "127.0.0.1"
    var localPort: Int = 0

    /// Start this tunnel as soon as its host connects.
    var startsAutomatically: Bool = false

    var host: Host?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String = "", kind: TunnelKind = .local) {
        self.name = name
        self.kindRaw = kind.rawValue
    }
}

enum TunnelKind: String, CaseIterable, Sendable, Identifiable {
    /// `ssh -L`
    case local
    /// `ssh -R`
    case remote
    /// `ssh -D`, a SOCKS5 proxy
    case dynamic

    var id: String { rawValue }
}

extension Tunnel {
    var kind: TunnelKind {
        get { TunnelKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    /// The `ssh` flag this tunnel corresponds to, shown in the UI.
    ///
    /// People who use tunnels know `-L` and `-R` and reliably mix up which is
    /// which; showing the flag next to the addresses is the fastest way to say
    /// which direction this one runs.
    var commandLineEquivalent: String {
        switch kind {
        case .local:
            return "-L \(listenAddress):\(listenPort):\(remoteHost):\(remotePort)"
        case .remote:
            return "-R \(remoteBindAddress):\(remoteBindPort):\(localHost):\(localPort)"
        case .dynamic:
            return "-D \(listenAddress):\(listenPort)"
        }
    }

    /// Whether this tunnel is complete enough to start.
    var isValid: Bool {
        switch kind {
        case .local:
            return isValidPort(listenPort, allowingZero: true)
                && !remoteHost.isEmpty
                && isValidPort(remotePort, allowingZero: false)
        case .remote:
            return isValidPort(remoteBindPort, allowingZero: true)
                && !localHost.isEmpty
                && isValidPort(localPort, allowingZero: false)
        case .dynamic:
            return isValidPort(listenPort, allowingZero: true)
        }
    }

    /// True when this tunnel makes itself reachable from the network rather
    /// than only from this device. Not forbidden — it is sometimes exactly
    /// what is wanted — but never the default and always said out loud.
    var isExposedToNetwork: Bool {
        switch kind {
        case .local, .dynamic:
            return !RemotePath.isLoopbackAddress(listenAddress)
        case .remote:
            // An empty bind address asks the server for all interfaces, which
            // most servers refuse unless `GatewayPorts` allows it.
            return remoteBindAddress.isEmpty || !RemotePath.isLoopbackAddress(remoteBindAddress)
        }
    }

    private func isValidPort(_ port: Int, allowingZero: Bool) -> Bool {
        allowingZero ? (0...65_535).contains(port) : (1...65_535).contains(port)
    }

    var localForward: LocalPortForward {
        LocalPortForward(
            listenAddress: listenAddress,
            listenPort: listenPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
    }

    var remoteForward: RemotePortForward {
        RemotePortForward(
            remoteBindAddress: remoteBindAddress,
            remoteBindPort: remoteBindPort,
            localHost: localHost,
            localPort: localPort
        )
    }

    var dynamicForward: DynamicPortForward {
        DynamicPortForward(listenAddress: listenAddress, listenPort: listenPort)
    }
}
