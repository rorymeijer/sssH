import Foundation
import XCTest
@testable import ssshCore

/// Host-key handling is the one place where a bug is a security bug, so these
/// tests pin the three outcomes: known key is silent, unknown key asks, and a
/// mismatch is refused unless something explicitly overrides it.
final class HostKeyPolicyTests: XCTestCase {
    private let endpoint = SSHEndpoint(hostname: "example.test", port: 2222)

    private func key(_ seed: UInt8, algorithm: String = "ssh-ed25519") -> SSHHostKey {
        SSHHostKey(algorithm: algorithm, wireFormat: [seed, seed, seed], sha256Fingerprint: "SHA256:fake\(seed)")
    }

    func testStoredKeyIsAcceptedWithoutPrompting() async {
        let stored = key(1)
        let store = InMemoryStore(seed: [endpoint.knownHostsKey: [stored]])
        let verifier = RecordingVerifier(decision: .reject)
        let policy = SSHKnownHostsPolicy(store: store, verifier: verifier)

        let accepted = await policy.validate(stored, for: endpoint)

        XCTAssertTrue(accepted)
        XCTAssertEqual(verifier.prompts.count, 0, "a trusted key must not bother the user")
    }

    func testUnknownHostIsPromptedAsUnknownAndCanBeRemembered() async {
        let store = InMemoryStore()
        let verifier = RecordingVerifier(decision: .trustAndRemember)
        let policy = SSHKnownHostsPolicy(store: store, verifier: verifier)

        let accepted = await policy.validate(key(7), for: endpoint)

        XCTAssertTrue(accepted)
        XCTAssertEqual(verifier.prompts.count, 1)
        guard case .unknownHost = verifier.prompts[0] else {
            return XCTFail("a first connection must be reported as unknownHost, not as a mismatch")
        }
        let remembered = await store.trustedKeys(for: endpoint)
        XCTAssertEqual(remembered, [key(7)])
    }

    func testTrustOnceDoesNotPersist() async {
        let store = InMemoryStore()
        let policy = SSHKnownHostsPolicy(store: store, verifier: RecordingVerifier(decision: .trustOnce))

        XCTAssertTrue(await policy.validate(key(7), for: endpoint))
        let remembered = await store.trustedKeys(for: endpoint)
        XCTAssertTrue(remembered.isEmpty)
    }

    func testMismatchIsReportedAsMismatchAndRejectedByDefault() async {
        let store = InMemoryStore(seed: [endpoint.knownHostsKey: [key(1)]])
        let verifier = RecordingVerifier(decision: .reject)
        let policy = SSHKnownHostsPolicy(store: store, verifier: verifier)

        let accepted = await policy.validate(key(2), for: endpoint)

        XCTAssertFalse(accepted)
        guard case .mismatch(_, let presented, let trusted) = verifier.prompts[0] else {
            return XCTFail("expected a mismatch prompt")
        }
        XCTAssertEqual(presented, key(2))
        XCTAssertEqual(trusted, [key(1)])
    }

    func testDefaultVerifierFailsClosed() async {
        let store = InMemoryStore()
        let policy = SSHKnownHostsPolicy(store: store, verifier: RejectingHostKeyVerifier())
        XCTAssertFalse(await policy.validate(key(9), for: endpoint))
    }

    func testAHostLegitimatelyOffersSeveralAlgorithms() async {
        let ed25519 = key(1, algorithm: "ssh-ed25519")
        let rsa = key(1, algorithm: "rsa-sha2-512")
        let store = InMemoryStore(seed: [endpoint.knownHostsKey: [ed25519, rsa]])
        let policy = SSHKnownHostsPolicy(store: store, verifier: RecordingVerifier(decision: .reject))

        // Same wire bytes, different algorithm: these are different keys, and
        // both are trusted, so neither should prompt.
        XCTAssertTrue(await policy.validate(ed25519, for: endpoint))
        XCTAssertTrue(await policy.validate(rsa, for: endpoint))
    }

    func testFingerprintIsNotPartOfKeyIdentity() {
        let withFingerprint = SSHHostKey(algorithm: "ssh-ed25519", wireFormat: [1, 2], sha256Fingerprint: "SHA256:abc")
        let withoutFingerprint = SSHHostKey(algorithm: "ssh-ed25519", wireFormat: [1, 2])

        // An entry loaded from a known_hosts file has no cached fingerprint and
        // must still match the live key.
        XCTAssertEqual(withFingerprint, withoutFingerprint)
    }

    func testKnownHostsKeyMatchesOpenSSHBracketForm() {
        XCTAssertEqual(SSHEndpoint(hostname: "a.test").knownHostsKey, "a.test")
        XCTAssertEqual(SSHEndpoint(hostname: "a.test", port: 2222).knownHostsKey, "[a.test]:2222")
    }

    // MARK: - Doubles

    private final class RecordingVerifier: SSHHostKeyVerifier, @unchecked Sendable {
        private let decision: SSHHostKeyDecision
        private let lock = NSLock()
        private var recorded: [SSHHostKeyPrompt] = []

        init(decision: SSHHostKeyDecision) { self.decision = decision }

        var prompts: [SSHHostKeyPrompt] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func evaluate(_ prompt: SSHHostKeyPrompt) async -> SSHHostKeyDecision {
            lock.lock()
            recorded.append(prompt)
            lock.unlock()
            return decision
        }
    }

    private final class InMemoryStore: SSHKnownHostsStore, @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: [SSHHostKey]]

        init(seed: [String: [SSHHostKey]] = [:]) { self.keys = seed }

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
}
