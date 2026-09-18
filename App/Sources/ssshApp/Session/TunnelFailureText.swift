import Foundation
import ssshCore

/// Turns a tunnel failure into something worth showing a person.
///
/// The three ways this goes wrong lead to three different things to do, which
/// is why ``SSHTransportError/PortForwardProblem`` is an enum rather than a
/// message: a port already in use is fixed by picking another, a server
/// refusing to listen is fixed in `sshd_config`, and a local target that
/// cannot be reached is fixed by starting whatever was meant to be listening.
enum TunnelFailureText {
    static func describe(_ error: Error) -> String {
        guard let transportError = error as? SSHTransportError else {
            return ConnectionFailureText.describe(error)
        }

        guard case .portForwardingFailed(let problem) = transportError else {
            return ConnectionFailureText.describe(error)
        }

        switch problem {
        case .localBindFailed(let address, let port, let underlying):
            let base = port < 1024
                ? String(localized: "Poort \(port) op \(address) kan niet worden geopend. Poorten onder 1024 zijn voorbehouden aan het systeem.",
                         comment: "A local tunnel could not bind a privileged port")
                : String(localized: "Poort \(port) op \(address) kan niet worden geopend. Waarschijnlijk is die al in gebruik.",
                         comment: "A local tunnel could not bind; the port is most likely taken")
            guard let underlying else { return base }
            return String(localized: "\(base) (\(underlying))",
                          comment: "Appends a technical reason to a tunnel failure")

        case .serverRefusedListen(let address, let port):
            return String(localized: "De server wil niet luisteren op \(address):\(port). Vaak staat GatewayPorts uit, of is de poort daar al bezet.",
                          comment: "The server refused a remote forward request")

        case .localTargetUnreachable(let host, let port, _):
            return String(localized: "Er kwam een verbinding binnen, maar \(host):\(port) op dit apparaat antwoordde niet.",
                          comment: "A remote forward arrived but the local destination was not listening")
        }
    }
}
