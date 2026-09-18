import Foundation

/// What sssh makes of an OpenSSH config file.
///
/// Separate from the parser on purpose: the parser says what the file
/// contains and can be checked against `ssh -G`, and this says what sssh can
/// do with it. Mixing them would mean the parser's correctness depended on
/// which settings the app happens to support this month.
public struct SSHConfigImport: Sendable {
    public var hosts: [ImportableHost]
    /// Problems with the file as a whole, rather than with one host.
    public var warnings: [ImportWarning]

    public init(hosts: [ImportableHost] = [], warnings: [ImportWarning] = []) {
        self.hosts = hosts
        self.warnings = warnings
    }
}

public struct ImportableHost: Identifiable, Sendable {
    public var id: String { alias }

    /// The name in the `Host` line, which is what people type and so what the
    /// saved host is called.
    public var alias: String
    public var hostname: String
    public var username: String?
    public var port: Int?
    /// Paths as written, `~` and all. Resolving them needs the file system,
    /// and the importer does not read keys — it records where they were said
    /// to be, and the user supplies them.
    public var identityFiles: [String]
    /// The `ProxyJump` alias, unresolved. Linking it to a saved host is the
    /// app's job, once it knows what got imported.
    public var proxyJump: String?
    public var keepAliveIntervalSeconds: Int?
    public var setEnvironment: [String: String]
    public var tunnels: [ImportableTunnel]
    public var warnings: [ImportWarning]

    public init(
        alias: String,
        hostname: String,
        username: String? = nil,
        port: Int? = nil,
        identityFiles: [String] = [],
        proxyJump: String? = nil,
        keepAliveIntervalSeconds: Int? = nil,
        setEnvironment: [String: String] = [:],
        tunnels: [ImportableTunnel] = [],
        warnings: [ImportWarning] = []
    ) {
        self.alias = alias
        self.hostname = hostname
        self.username = username
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.setEnvironment = setEnvironment
        self.tunnels = tunnels
        self.warnings = warnings
    }
}

public struct ImportableTunnel: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case local
        case remote
        case dynamic
    }

    public var kind: Kind
    public var listenAddress: String
    public var listenPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(kind: Kind, listenAddress: String, listenPort: Int, targetHost: String = "", targetPort: Int = 0) {
        self.kind = kind
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }
}

/// Something in the file that sssh will not do, or cannot.
///
/// Every one of these is shown. An import that silently drops half a host's
/// settings produces a saved connection that behaves differently from the same
/// alias in `ssh`, and the user finds out at the worst moment.
public enum ImportWarning: Hashable, Sendable {
    /// `ProxyCommand`. Never run: it is an arbitrary shell command taken from a
    /// file, and a config file can arrive by import, by sync or from a
    /// colleague. `ProxyJump` does the common case and is supported.
    case proxyCommandNotSupported(command: String, line: Int)
    /// `Match exec`, `Match canonical`, `Match final`. Deciding whether the
    /// block applies would mean running a command or doing OpenSSH's
    /// canonicalisation pass; the block is skipped and its settings left out.
    case matchNotEvaluated(keyword: String, line: Int)
    /// `Include`. Reading it needs the file system, and the app asks for the
    /// files it is allowed to read rather than going looking.
    case includeNotFollowed(path: String, line: Int)
    /// A keyword sssh has no equivalent for. Listed, not applied.
    case settingIgnored(keyword: String, value: String, line: Int)
    /// A value that should be a number and is not.
    case malformedValue(keyword: String, value: String, line: Int)
    case unparsedLine(text: String, line: Int)

    public var line: Int {
        switch self {
        case .proxyCommandNotSupported(_, let line), .matchNotEvaluated(_, let line),
             .includeNotFollowed(_, let line), .settingIgnored(_, _, let line),
             .malformedValue(_, _, let line), .unparsedLine(_, let line):
            return line
        }
    }
}

public enum SSHConfigImporter {
    /// Keywords sssh understands. Anything else is reported rather than
    /// silently dropped.
    private static let understood: Set<String> = [
        "hostname", "user", "port", "identityfile", "proxyjump",
        "serveraliveinterval", "setenv", "localforward", "remoteforward",
        "dynamicforward", "requesttty", "forwardagent", "compression",
        "connecttimeout", "addkeystoagent", "identitiesonly", "sendenv",
        "stricthostkeychecking", "userknownhostsfile", "hashknownhosts",
        "loglevel", "batchmode", "escapechar", "controlmaster", "controlpath",
        "controlpersist", "serveralivecountmax", "tcpkeepalive",
    ]

    /// Keywords that are understood as configuration but have no effect in
    /// sssh, because it is not OpenSSH: the multiplexing ones, the ones about
    /// where OpenSSH keeps its files, and the ones about its terminal escape
    /// handling.
    private static let acknowledgedButUnused: Set<String> = [
        "controlmaster", "controlpath", "controlpersist", "escapechar",
        "batchmode", "loglevel", "hashknownhosts", "userknownhostsfile",
        "addkeystoagent", "identitiesonly", "sendenv", "tcpkeepalive",
        "serveralivecountmax", "stricthostkeychecking",
    ]

    public static func makeImport(from file: SSHConfigFile, localUser: String? = nil) -> SSHConfigImport {
        var result = SSHConfigImport()

        for include in file.includes {
            result.warnings.append(.includeNotFollowed(path: include.value, line: include.lineNumber))
        }
        for unparsed in file.unparsedLines {
            result.warnings.append(.unparsedLine(text: unparsed.value, line: unparsed.lineNumber))
        }
        for block in file.blocks {
            guard case .match(let criteria) = block.scope else { continue }
            for criterion in criteria {
                guard case .unevaluatable(let keyword, _) = criterion else { continue }
                result.warnings.append(.matchNotEvaluated(keyword: keyword, line: block.lineNumber))
            }
        }

        for alias in file.importableAliases {
            result.hosts.append(makeHost(alias: alias, from: file, localUser: localUser))
        }
        return result
    }

    private static func makeHost(alias: String, from file: SSHConfigFile, localUser: String?) -> ImportableHost {
        let settings = SSHConfigParser.settings(for: alias, in: file, localUser: localUser)
        var host = ImportableHost(alias: alias, hostname: alias)
        var environment: [String: String] = [:]

        for setting in settings {
            switch setting.keyword.lowercased() {
            case "hostname":
                host.hostname = setting.value
            case "user":
                host.username = setting.value
            case "port":
                guard let port = Int(setting.value), (1...65_535).contains(port) else {
                    host.warnings.append(.malformedValue(keyword: setting.keyword, value: setting.value, line: setting.lineNumber))
                    continue
                }
                host.port = port
            case "proxyjump":
                // `none` is how a later block cancels an earlier one.
                host.proxyJump = setting.value.lowercased() == "none" ? nil : setting.value
            case "proxycommand":
                host.warnings.append(.proxyCommandNotSupported(command: setting.value, line: setting.lineNumber))
            case "serveraliveinterval":
                guard let seconds = Int(setting.value), seconds >= 0 else {
                    host.warnings.append(.malformedValue(keyword: setting.keyword, value: setting.value, line: setting.lineNumber))
                    continue
                }
                host.keepAliveIntervalSeconds = seconds
            case "setenv":
                for token in SSHConfigParser.tokenise(setting.value) {
                    guard let equals = token.firstIndex(of: "=") else { continue }
                    environment[String(token[token.startIndex..<equals])] = String(token[token.index(after: equals)...])
                }
            case "identityfile", "localforward", "remoteforward", "dynamicforward":
                break // Accumulating keywords, collected below.
            default:
                let keyword = setting.keyword.lowercased()
                if !understood.contains(keyword) || acknowledgedButUnused.contains(keyword) {
                    host.warnings.append(.settingIgnored(keyword: setting.keyword, value: setting.value, line: setting.lineNumber))
                }
            }
        }

        // These four accumulate rather than being first-value-wins, which is
        // the one place OpenSSH's own rule does not apply.
        host.identityFiles = SSHConfigParser.values(of: "IdentityFile", for: alias, in: file, localUser: localUser)
        host.setEnvironment = environment

        for value in SSHConfigParser.values(of: "LocalForward", for: alias, in: file, localUser: localUser) {
            appendTunnel(parseForward(value, kind: .local), to: &host, keyword: "LocalForward", value: value, in: file, alias: alias)
        }
        for value in SSHConfigParser.values(of: "RemoteForward", for: alias, in: file, localUser: localUser) {
            appendTunnel(parseForward(value, kind: .remote), to: &host, keyword: "RemoteForward", value: value, in: file, alias: alias)
        }
        for value in SSHConfigParser.values(of: "DynamicForward", for: alias, in: file, localUser: localUser) {
            appendTunnel(parseDynamicForward(value), to: &host, keyword: "DynamicForward", value: value, in: file, alias: alias)
        }

        return host
    }

    private static func appendTunnel(
        _ tunnel: ImportableTunnel?,
        to host: inout ImportableHost,
        keyword: String,
        value: String,
        in file: SSHConfigFile,
        alias: String
    ) {
        if let tunnel {
            host.tunnels.append(tunnel)
        } else {
            host.warnings.append(.malformedValue(keyword: keyword, value: value, line: 0))
        }
    }

    /// `LocalForward [bind_address:]port host:hostport`
    ///
    /// Only the two-token form. The packed `port:host:hostport` spelling works
    /// on the command line and OpenSSH rejects it in a config file — "Missing
    /// target argument" — so accepting it here would import a tunnel from a
    /// line that `ssh` itself refuses to start with. Reporting it as malformed
    /// says the same thing `ssh` says.
    static func parseForward(_ value: String, kind: ImportableTunnel.Kind) -> ImportableTunnel? {
        let tokens = SSHConfigParser.tokenise(value)
        guard tokens.count == 2 else { return nil }
        guard let listen = parseEndpoint(tokens[0], defaultAddress: "127.0.0.1"),
              let target = parseEndpoint(tokens[1], defaultAddress: "")
        else {
            return nil
        }
        guard !target.address.isEmpty, target.port > 0 else { return nil }
        return ImportableTunnel(
            kind: kind,
            listenAddress: listen.address,
            listenPort: listen.port,
            targetHost: target.address,
            targetPort: target.port
        )
    }

    /// `DynamicForward [bind_address:]port`
    static func parseDynamicForward(_ value: String) -> ImportableTunnel? {
        let tokens = SSHConfigParser.tokenise(value)
        guard let first = tokens.first, let endpoint = parseEndpoint(first, defaultAddress: "127.0.0.1") else {
            return nil
        }
        return ImportableTunnel(kind: .dynamic, listenAddress: endpoint.address, listenPort: endpoint.port)
    }

    /// `port`, `host:port`, or `[v6:address]:port`.
    static func parseEndpoint(_ text: String, defaultAddress: String) -> (address: String, port: Int)? {
        if let port = Int(text), (0...65_535).contains(port) {
            return (defaultAddress, port)
        }

        if text.hasPrefix("["), let closing = text.lastIndex(of: "]") {
            let address = String(text[text.index(after: text.startIndex)..<closing])
            let remainder = text[text.index(after: closing)...]
            guard remainder.hasPrefix(":"), let port = Int(remainder.dropFirst()) else { return nil }
            return (address, port)
        }

        guard let colon = text.lastIndex(of: ":") else { return nil }
        let address = String(text[text.startIndex..<colon])
        guard let port = Int(text[text.index(after: colon)...]), (0...65_535).contains(port) else { return nil }
        return (address, port)
    }
}
