import XCTest
@testable import ssshCore

/// The forward expectations here match what `ssh -G` prints for the same
/// lines, including the ones it refuses.
final class SSHConfigImportTests: XCTestCase {
    func testImportsTheObviousThings() throws {
        let file = SSHConfigParser.parse("""
        Host prod
            HostName prod.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_prod
            IdentityFile ~/.ssh/id_backup
            ProxyJump bastion
            ServerAliveInterval 45
            SetEnv FOO=bar BAZ=qux
        """)
        let result = SSHConfigImporter.makeImport(from: file)
        let host = try XCTUnwrap(result.hosts.first)

        XCTAssertEqual(host.alias, "prod")
        XCTAssertEqual(host.hostname, "prod.example.com")
        XCTAssertEqual(host.username, "deploy")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.identityFiles, ["~/.ssh/id_prod", "~/.ssh/id_backup"])
        XCTAssertEqual(host.proxyJump, "bastion")
        XCTAssertEqual(host.keepAliveIntervalSeconds, 45)
        XCTAssertEqual(host.setEnvironment, ["FOO": "bar", "BAZ": "qux"])
        XCTAssertTrue(host.warnings.isEmpty, "\(host.warnings)")
    }

    /// A `Host` line with no `HostName` connects to the alias, which is what
    /// `ssh -G` reports too.
    func testHostNameDefaultsToTheAlias() throws {
        let file = SSHConfigParser.parse("Host bare\n    User someone\n")
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertEqual(host.hostname, "bare")
    }

    func testForwardsMatchWhatSSHAccepts() throws {
        let file = SSHConfigParser.parse("""
        Host f
            HostName f.example.com
            LocalForward 8080 intranet:80
            LocalForward 127.0.0.1:9090 10.0.0.5:443
            LocalForward 0.0.0.0:7070 example.com:8000
            RemoteForward 2222 localhost:22
            DynamicForward 1080
            DynamicForward 127.0.0.1:1081
        """)
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertEqual(host.tunnels.count, 6)

        XCTAssertEqual(host.tunnels[0], ImportableTunnel(kind: .local, listenAddress: "127.0.0.1", listenPort: 8080, targetHost: "intranet", targetPort: 80))
        XCTAssertEqual(host.tunnels[1], ImportableTunnel(kind: .local, listenAddress: "127.0.0.1", listenPort: 9090, targetHost: "10.0.0.5", targetPort: 443))
        // Binding 0.0.0.0 is imported as written. It is the user's file; sssh
        // says what it means rather than quietly narrowing it.
        XCTAssertEqual(host.tunnels[2], ImportableTunnel(kind: .local, listenAddress: "0.0.0.0", listenPort: 7070, targetHost: "example.com", targetPort: 8000))
        XCTAssertEqual(host.tunnels[3], ImportableTunnel(kind: .remote, listenAddress: "127.0.0.1", listenPort: 2222, targetHost: "localhost", targetPort: 22))
        XCTAssertEqual(host.tunnels[4], ImportableTunnel(kind: .dynamic, listenAddress: "127.0.0.1", listenPort: 1080))
        XCTAssertEqual(host.tunnels[5], ImportableTunnel(kind: .dynamic, listenAddress: "127.0.0.1", listenPort: 1081))
    }

    func testIPv6ForwardTarget() {
        let tunnel = SSHConfigImporter.parseForward("8080 [2001:db8::1]:443", kind: .local)
        XCTAssertEqual(tunnel?.targetHost, "2001:db8::1")
        XCTAssertEqual(tunnel?.targetPort, 443)
    }

    /// OpenSSH rejects the packed `port:host:hostport` spelling in a config
    /// file — it is a command-line form — so importing it would create a
    /// tunnel from a line `ssh` refuses to start with.
    func testPackedForwardFormIsReportedRatherThanImported() throws {
        let file = SSHConfigParser.parse("""
        Host f
            HostName f.example.com
            LocalForward 5000:packed.example.com:5001
        """)
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertTrue(host.tunnels.isEmpty)
        XCTAssertTrue(host.warnings.contains { if case .malformedValue = $0 { return true } else { return false } })
    }

    /// Never run, and never silently dropped either. `ProxyCommand` is an
    /// arbitrary shell command out of a file that can arrive by import, by
    /// sync or from a colleague.
    func testProxyCommandIsReportedAndNotImported() throws {
        let file = SSHConfigParser.parse("""
        Host via
            HostName via.example.com
            ProxyCommand ssh -W %h:%p bastion
        """)
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertNil(host.proxyJump)
        guard case .proxyCommandNotSupported(let command, _)? = host.warnings.first else {
            return XCTFail("expected a ProxyCommand warning, got \(host.warnings)")
        }
        XCTAssertEqual(command, "ssh -W %h:%p bastion")
    }

    func testProxyJumpNoneClearsIt() throws {
        let file = SSHConfigParser.parse("""
        Host a
            ProxyJump none

        Host *
            ProxyJump bastion
        """)
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertNil(host.proxyJump)
    }

    func testIncludesAreReportedRatherThanFollowed() {
        let file = SSHConfigParser.parse("Include ~/.ssh/config.d/*\nHost a\n    HostName a.example.com\n")
        let result = SSHConfigImporter.makeImport(from: file)
        guard case .includeNotFollowed(let path, _)? = result.warnings.first else {
            return XCTFail("expected an Include warning, got \(result.warnings)")
        }
        XCTAssertEqual(path, "~/.ssh/config.d/*")
    }

    func testUnsupportedSettingsAreListed() throws {
        let file = SSHConfigParser.parse("""
        Host a
            HostName a.example.com
            PKCS11Provider /usr/lib/opensc-pkcs11.so
            ControlMaster auto
        """)
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        let keywords = host.warnings.compactMap { warning -> String? in
            if case .settingIgnored(let keyword, _, _) = warning { return keyword } else { return nil }
        }
        XCTAssertTrue(keywords.contains("PKCS11Provider"))
        // Understood as configuration, but sssh is not OpenSSH and does not
        // multiplex over a control socket — so it is listed, not applied.
        XCTAssertTrue(keywords.contains("ControlMaster"))
    }

    func testMalformedPortIsReported() throws {
        let file = SSHConfigParser.parse("Host a\n    Port seventy\n")
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertNil(host.port)
        XCTAssertTrue(host.warnings.contains { if case .malformedValue = $0 { return true } else { return false } })
    }

    func testOutOfRangePortIsReported() throws {
        let file = SSHConfigParser.parse("Host a\n    Port 70000\n")
        let host = try XCTUnwrap(SSHConfigImporter.makeImport(from: file).hosts.first)
        XCTAssertNil(host.port)
        XCTAssertTrue(host.warnings.contains { if case .malformedValue = $0 { return true } else { return false } })
    }

    func testWildcardBlocksContributeSettingsWithoutBecomingHosts() throws {
        let file = SSHConfigParser.parse("""
        Host *
            User everyone

        Host real
            HostName real.example.com
        """)
        let result = SSHConfigImporter.makeImport(from: file)
        XCTAssertEqual(result.hosts.map(\.alias), ["real"])
        XCTAssertEqual(try XCTUnwrap(result.hosts.first).username, "everyone")
    }
}
