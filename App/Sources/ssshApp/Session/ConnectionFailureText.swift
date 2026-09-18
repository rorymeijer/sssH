import Foundation
import ssshCore

/// Turns a transport error into something worth showing a person.
///
/// This is the one place that knows how to phrase a failure, and it is
/// deliberately in the app rather than in `ssshCore`: the transport reports
/// facts (which endpoint, which credentials were tried, which methods the
/// server accepts) and the app turns those into Dutch through the String
/// Catalog. The keys here are what the catalog translates.
enum ConnectionFailureText {
    static func describe(_ error: Error) -> String {
        guard let transportError = error as? SSHTransportError else {
            return String(localized: "Er is iets misgegaan: \(String(describing: error))",
                          comment: "Fallback when a failure has no better description")
        }

        switch transportError {
        case .unreachable(let endpoint, let underlying):
            if let underlying {
                return String(localized: "Kan \(endpoint.description) niet bereiken (\(underlying)).",
                              comment: "The TCP connection could not be made; second placeholder is a technical reason")
            }
            return String(localized: "Kan \(endpoint.description) niet bereiken.",
                          comment: "The TCP connection could not be made")

        case .hostKeyRejected(let endpoint, _):
            return String(localized: "De hostsleutel van \(endpoint.description) is geweigerd. Er is geen verbinding gemaakt.",
                          comment: "Shown after the user refuses a host key, or after a mismatch")

        case .authenticationFailed(let tried, let accepted):
            // Joined before interpolation: a separator literal inside a
            // localised string's interpolation confuses string extraction.
            let separator = ", "
            let triedText = tried.isEmpty
                ? String(localized: "geen", comment: "Placeholder when no credential was offered")
                : tried.joined(separator: separator)
            let acceptedText = accepted.joined(separator: separator)
            return String(localized: "Aanmelden is mislukt. Geprobeerd: \(triedText). De server accepteert: \(acceptedText).",
                          comment: "Authentication failed; lists what was tried and what the server accepts")

        case .credentialUnusable(let credential, let reason):
            switch reason {
            case .wrongPassphrase:
                return String(localized: "De wachtwoordzin voor \(credential) klopt niet.",
                              comment: "The passphrase for a private key was wrong")
            case .passphraseRequired:
                return String(localized: "\(credential) is beveiligd met een wachtwoordzin.",
                              comment: "An encrypted key was supplied without its passphrase")
            case .malformedKey:
                return String(localized: "\(credential) kon niet worden gelezen als sleutelbestand.",
                              comment: "The key file could not be parsed at all")
            case .unsupportedKeyType(let type):
                return String(localized: "sssh kan sleutels van het type \(type) nog niet gebruiken. Zet de sleutel om met ssh-keygen.",
                              comment: "The key file is a type the app cannot use yet; suggests converting it")
            }

        case .unsupported(let capability):
            return unsupportedText(capability)

        case .connectionLost(let reason):
            switch reason {
            case .keepAliveTimeout:
                return String(localized: "De verbinding reageert niet meer.",
                              comment: "Keep-alive probes went unanswered")
            case .remoteClosed:
                return String(localized: "De verbinding is door de server verbroken.",
                              comment: "The remote end closed the connection")
            case .userInitiated:
                return String(localized: "De verbinding is verbroken.",
                              comment: "The user disconnected")
            case .failed(let detail):
                return detail
            }

        case .notConnected:
            return String(localized: "Er is geen verbinding.",
                          comment: "An operation was attempted with no connection")

        case .channelRequestFailed(let detail):
            return String(localized: "De server weigerde een verzoek: \(detail)",
                          comment: "A channel request was refused; placeholder is a technical detail")

        case .timedOut(let operation, _):
            return String(localized: "Time-out tijdens \(operation).",
                          comment: "An operation took too long; placeholder names the operation")

        case .portForwardingFailed:
            // `TunnelFailureText` is the one place that knows how to phrase a
            // forward that could not be set up — which port, which end, and
            // whether it was us or the server that refused. Duplicating that
            // wording here is how the two drift apart.
            return TunnelFailureText.describe(error)
        }
    }

    /// Named separately because these are the sentences that have to be honest
    /// about a gap rather than suggest a retry.
    private static func unsupportedText(_ capability: SSHTransportError.Capability) -> String {
        switch capability {
        case .keyboardInteractiveAuthentication:
            return String(localized: "De extra verificatie is afgebroken.",
                          comment: "A keyboard-interactive challenge was cancelled or could not be answered")
        case .agentForwarding:
            return String(localized: "sssh ondersteunt ssh-agent nog niet.",
                          comment: "Agent forwarding is not implemented")
        case .sftp:
            return String(localized: "Bestandsoverdracht komt in een volgende versie.",
                          comment: "SFTP is not implemented yet")
        case .localPortForwarding, .remotePortForwarding, .dynamicPortForwarding:
            return String(localized: "Poortdoorsturing komt in een volgende versie.",
                          comment: "Port forwarding is not implemented yet")
        case .tmuxControlMode:
            return String(localized: "tmux-besturingsmodus wordt nog niet ondersteund.",
                          comment: "tmux control mode is not implemented")
        case .rsaPrivateKeyFiles, .ecdsaPrivateKeyFiles:
            return String(localized: "Dit sleuteltype wordt nog niet ondersteund.",
                          comment: "A private key file type is not supported")
        case .legacyKeyExchange:
            return String(localized: "Deze server gebruikt alleen verouderde versleuteling die sssh niet ondersteunt. Werk de server bij, of gebruik OpenSSH.",
                          comment: "The server only offers pre-2014 key exchange or ciphers")
        }
    }
}
