import Foundation
import ssshCore

/// How to reach the test host, and what to do once there.
struct SpikeConfiguration {
    enum Mode: String {
        /// Run the automated PTY conformance checks.
        case verify
        /// Hand the local terminal to the remote shell, for trying `vim`,
        /// `htop`, `tmux` and a window resize by hand.
        case interactive
    }

    var mode: Mode = .verify
    var hostname = "127.0.0.1"
    var port = 22
    var username = NSUserName()
    var password: String?
    var privateKeyPath: String?
    var passphrase: String?
    var columns = 80
    var rows = 24
    /// Trust whatever host key the server presents, printing its fingerprint.
    ///
    /// Off by default, and named so that nobody can enable it by accident:
    /// the whole point of the transport is that it fails closed.
    var trustAnyHostKey = false
    var expectedHostKeyFingerprint: String?
    var verbose = false

    static let usage = """
    sssh-ptyspike — Phase 0 interactive-PTY harness

    USAGE
      sssh-ptyspike [verify|interactive] [options]

    OPTIONS
      --host <host>             (default 127.0.0.1)
      --port <port>             (default 22)
      --user <name>             (default $USER)
      --password <password>     password authentication
      --key <path>              OpenSSH private key file
      --passphrase <phrase>     passphrase for --key
      --size <cols>x<rows>      initial PTY size (default 80x24)
      --host-key <SHA256:...>   require this host-key fingerprint
      --trust-any-host-key      accept any host key (test hosts only)
      --verbose                 log transport events
      -h, --help

    ENVIRONMENT
      Each option can also be given as SSSH_SPIKE_<OPTION>, e.g.
      SSSH_SPIKE_PASSWORD, so that CI never puts a secret in a command line.

    EXIT STATUS
      0  all checks passed (or were skipped)
      1  at least one check failed
      2  could not connect
    """

    /// Reads the environment first, then the command line, so an explicit flag
    /// always wins.
    static func parse(arguments: [String], environment: [String: String]) throws -> SpikeConfiguration {
        var configuration = SpikeConfiguration()

        func environmentValue(_ name: String) -> String? {
            let value = environment["SSSH_SPIKE_\(name)"]
            return (value?.isEmpty ?? true) ? nil : value
        }

        if let value = environmentValue("HOST") { configuration.hostname = value }
        if let value = environmentValue("PORT"), let port = Int(value) { configuration.port = port }
        if let value = environmentValue("USER") { configuration.username = value }
        if let value = environmentValue("PASSWORD") { configuration.password = value }
        if let value = environmentValue("KEY") { configuration.privateKeyPath = value }
        if let value = environmentValue("PASSPHRASE") { configuration.passphrase = value }
        if let value = environmentValue("HOST_KEY") { configuration.expectedHostKeyFingerprint = value }
        if environmentValue("TRUST_ANY_HOST_KEY") == "1" { configuration.trustAnyHostKey = true }

        var index = arguments.startIndex

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else {
                throw SpikeError.usage("\(flag) needs a value")
            }
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]

            switch argument {
            case "verify", "interactive":
                guard let mode = Mode(rawValue: argument) else { throw SpikeError.usage("unknown mode") }
                configuration.mode = mode
            case "--host": configuration.hostname = try nextValue(for: argument)
            case "--port":
                let raw = try nextValue(for: argument)
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw SpikeError.usage("--port must be 1-65535, got \(raw)")
                }
                configuration.port = port
            case "--user": configuration.username = try nextValue(for: argument)
            case "--password": configuration.password = try nextValue(for: argument)
            case "--key": configuration.privateKeyPath = try nextValue(for: argument)
            case "--passphrase": configuration.passphrase = try nextValue(for: argument)
            case "--size":
                let raw = try nextValue(for: argument)
                let parts = raw.lowercased().split(separator: "x")
                guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]) else {
                    throw SpikeError.usage("--size must look like 120x40, got \(raw)")
                }
                configuration.columns = columns
                configuration.rows = rows
            case "--host-key": configuration.expectedHostKeyFingerprint = try nextValue(for: argument)
            case "--trust-any-host-key": configuration.trustAnyHostKey = true
            case "--verbose": configuration.verbose = true
            case "-h", "--help": throw SpikeError.helpRequested
            default:
                throw SpikeError.usage("unknown argument \(argument)")
            }

            index += 1
        }

        if configuration.password == nil, configuration.privateKeyPath == nil {
            throw SpikeError.usage("one of --password or --key is required")
        }
        if configuration.expectedHostKeyFingerprint == nil, !configuration.trustAnyHostKey {
            throw SpikeError.usage("pass --host-key <SHA256:...> or, for a throwaway test host, --trust-any-host-key")
        }

        return configuration
    }

    func credentials() throws -> [SSHCredential] {
        var credentials: [SSHCredential] = []

        // Keys first, matching OpenSSH: a password prompt is the fallback.
        if let privateKeyPath {
            let text = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
            credentials.append(.privateKey(SSHPrivateKeyMaterial(
                openSSHPrivateKey: SecretString(text),
                passphrase: passphrase.map { SecretString($0) },
                label: (privateKeyPath as NSString).lastPathComponent
            )))
        }
        if let password {
            credentials.append(.password(SecretString(password)))
        }

        return credentials
    }

    var terminalSize: TerminalSize {
        TerminalSize(columns: columns, rows: rows)
    }

    var endpoint: SSHEndpoint {
        SSHEndpoint(hostname: hostname, port: port)
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case helpRequested

    var description: String {
        switch self {
        case .usage(let message): return message
        case .helpRequested: return SpikeConfiguration.usage
        }
    }
}
