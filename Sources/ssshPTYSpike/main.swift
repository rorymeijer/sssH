import Foundation
import Logging
import ssshCore
import ssshTransportNIOSSH

// Phase 0 harness. See docs/PHASE-0-BACKEND-DECISION.md for what it proved.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let configuration: SpikeConfiguration
do {
    configuration = try SpikeConfiguration.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
    )
} catch SpikeError.helpRequested {
    print(SpikeConfiguration.usage)
    exit(0)
} catch {
    fail("\(error)\n\n\(SpikeConfiguration.usage)", code: 2)
}

var logger = Logger(label: "nl.rorymeijer.sssh.spike")
logger.logLevel = configuration.verbose ? .trace : .notice

let credentials: [SSHCredential]
do {
    credentials = try configuration.credentials()
} catch {
    fail("could not read credentials: \(error)", code: 2)
}

let destination = SSHDestination(
    endpoint: configuration.endpoint,
    username: configuration.username,
    credentials: credentials,
    connectTimeout: .seconds(20)
)

let knownHosts = InMemoryKnownHostsStore()
let hostKeyPolicy = SSHKnownHostsPolicy(
    store: knownHosts,
    verifier: SpikeHostKeyVerifier(
        expectedFingerprint: configuration.expectedHostKeyFingerprint,
        trustAnything: configuration.trustAnyHostKey
    )
)

let transport = NIOSSHTransportFactory(logger: logger).makeTransport()

let info: SSHConnectionInfo
do {
    info = try await transport.connect(to: destination, hostKeyPolicy: hostKeyPolicy)
} catch {
    fail("could not connect to \(configuration.endpoint): \(error)", code: 2)
}

print("connected to \(info.endpoint) as \(info.username) using \(info.authenticatedWith)")
print("host key: \(info.hostKey.algorithm) \(info.hostKey.displayFingerprint)")

let shellConfiguration = SSHShellConfiguration(
    terminalType: .xterm256Color,
    initialSize: configuration.terminalSize,
    // `LC_ALL` keeps `stty`, `htop` and `vim` from picking a locale that
    // changes the strings the checks look for. Servers usually allow LANG/LC_*
    // through `AcceptEnv`; if not, the checks are written to tolerate it.
    environment: ["LC_ALL": "C"]
)

let session: any SSHShellSession
do {
    session = try await transport.openShell(shellConfiguration)
} catch {
    await transport.disconnect()
    fail("could not open an interactive shell: \(error)", code: 2)
}

switch configuration.mode {
case .interactive:
    print("attaching local terminal — exit the remote shell to finish\r")
    await InteractiveBridge(session: session).run(initialSize: configuration.terminalSize)
    await transport.disconnect()
    exit(0)

case .verify:
    let collector = OutputCollector()
    let drain = Task { await collector.consume(session) }

    let checks = SpikeChecks(
        transport: transport,
        session: session,
        collector: collector,
        configuration: configuration
    )
    let results = await checks.runAll()

    drain.cancel()
    await session.close()
    await transport.disconnect()

    print("")
    print("Phase 0 PTY conformance — \(configuration.endpoint)")
    print(String(repeating: "-", count: 72))

    var failures = 0
    for result in results {
        let milliseconds = Int(result.duration.seconds * 1000)
        let label: String
        switch result.outcome {
        case .passed(let detail):
            label = "PASS " + (detail.map { "— \($0)" } ?? "")
        case .skipped(let reason):
            label = "SKIP — \(reason)"
        case .expectedGap(let reason):
            label = "GAP  — \(reason)"
        case .failed(let reason):
            failures += 1
            label = "FAIL — \(reason)"
        }
        print("\(result.name.padded(to: 46)) \(String(milliseconds).padded(to: 6, alignRight: true))ms  \(label)")
    }

    print(String(repeating: "-", count: 72))
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

