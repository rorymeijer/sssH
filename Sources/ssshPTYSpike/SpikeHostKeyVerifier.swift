import Foundation
import ssshCore

/// Host-key policy for the harness.
///
/// Two modes, both non-interactive so the spike can run in CI:
/// pin a fingerprint (the real behaviour, and what CI uses once it knows the
/// test server's key), or explicitly trust anything (throwaway containers).
/// There is no "prompt the user" path here — that is the app's job — and no
/// silent default, so a misconfigured run fails rather than trusting a
/// stranger.
struct SpikeHostKeyVerifier: SSHHostKeyVerifier {
    let expectedFingerprint: String?
    let trustAnything: Bool

    func evaluate(_ prompt: SSHHostKeyPrompt) async -> SSHHostKeyDecision {
        switch prompt {
        case .unknownHost(let endpoint, let key):
            report("host key for \(endpoint): \(key.algorithm) \(key.displayFingerprint)")

            if let expectedFingerprint {
                guard key.sha256Fingerprint == expectedFingerprint else {
                    report("REJECTED: expected \(expectedFingerprint)")
                    return .reject
                }
                return .trustAndRemember
            }

            if trustAnything {
                report("accepted because --trust-any-host-key was given")
                return .trustAndRemember
            }

            return .reject

        case .mismatch(let endpoint, let presented, let trusted):
            // The loud case. Even in a test harness this is never waved
            // through: a mismatch during a spike run means the container was
            // rebuilt, and pretending otherwise would hide the same bug in the
            // app.
            report("""
            HOST KEY MISMATCH for \(endpoint)
              presented: \(presented.algorithm) \(presented.displayFingerprint)
              trusted:   \(trusted.map { "\($0.algorithm) \($0.displayFingerprint)" }.joined(separator: ", "))
            """)
            return .reject
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data(("[host key] " + message + "\n").utf8))
    }
}

/// An in-memory known-hosts store. The app backs this with SwiftData; the
/// harness only needs trust to last for one process.
final class InMemoryKnownHostsStore: SSHKnownHostsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: [SSHHostKey]] = [:]

    init(seed: [SSHEndpoint: [SSHHostKey]] = [:]) {
        for (endpoint, hostKeys) in seed {
            keys[endpoint.knownHostsKey] = hostKeys
        }
    }

    func trustedKeys(for endpoint: SSHEndpoint) async -> [SSHHostKey] {
        lock.lock()
        defer { lock.unlock() }
        return keys[endpoint.knownHostsKey] ?? []
    }

    func remember(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {
        lock.lock()
        defer { lock.unlock() }
        var existing = keys[endpoint.knownHostsKey] ?? []
        if !existing.contains(key) { existing.append(key) }
        keys[endpoint.knownHostsKey] = existing
    }

    func forget(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {
        lock.lock()
        defer { lock.unlock() }
        keys[endpoint.knownHostsKey]?.removeAll { $0 == key }
    }
}
