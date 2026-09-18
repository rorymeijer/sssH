import XCTest
@testable import ssshTransportNIOSSH

/// Matching an inbound `forwarded-tcpip` channel to the tunnel that asked for
/// it. Getting this wrong sends someone else's connection to the wrong local
/// service, so the fallback is deliberately narrow.
final class RemoteForwardRegistryTests: XCTestCase {
    func testExactMatch() {
        let registry = RemoteForwardRegistry()
        registry.register(bindAddress: "127.0.0.1", boundPort: 8080, localHost: "localhost", localPort: 3000, counters: PortForwardCounters())

        let entry = registry.destination(listeningHost: "127.0.0.1", listeningPort: 8080)
        XCTAssertEqual(entry?.localHost, "localhost")
        XCTAssertEqual(entry?.localPort, 3000)
    }

    /// Servers do not agree on what to echo back in `listeningHost`: OpenSSH
    /// returns what was asked for, others normalise it. A single tunnel on
    /// that port is unambiguous whatever the server calls the address.
    func testFallsBackToThePortWhenOnlyOneTunnelOwnsIt() {
        let registry = RemoteForwardRegistry()
        registry.register(bindAddress: "", boundPort: 8080, localHost: "localhost", localPort: 3000, counters: PortForwardCounters())

        XCTAssertEqual(registry.destination(listeningHost: "0.0.0.0", listeningPort: 8080)?.localPort, 3000)
        XCTAssertEqual(registry.destination(listeningHost: "localhost", listeningPort: 8080)?.localPort, 3000)
    }

    /// Two tunnels on the same port and different addresses. Guessing here
    /// would hand a connection to the wrong service, so an inexact match is
    /// refused instead.
    func testAmbiguousPortIsNotGuessed() {
        let registry = RemoteForwardRegistry()
        registry.register(bindAddress: "127.0.0.1", boundPort: 8080, localHost: "localhost", localPort: 3000, counters: PortForwardCounters())
        registry.register(bindAddress: "10.0.0.5", boundPort: 8080, localHost: "localhost", localPort: 4000, counters: PortForwardCounters())

        XCTAssertNil(registry.destination(listeningHost: "192.168.0.1", listeningPort: 8080))
        // The exact ones still resolve.
        XCTAssertEqual(registry.destination(listeningHost: "10.0.0.5", listeningPort: 8080)?.localPort, 4000)
    }

    func testUnknownPortIsRefused() {
        let registry = RemoteForwardRegistry()
        registry.register(bindAddress: "127.0.0.1", boundPort: 8080, localHost: "localhost", localPort: 3000, counters: PortForwardCounters())
        XCTAssertNil(registry.destination(listeningHost: "127.0.0.1", listeningPort: 9090))
    }

    /// A connection can arrive between the cancel request going out and the
    /// server acting on it. After unregistering it must be refused, not
    /// forwarded to a tunnel the user has closed.
    func testUnregisteredTunnelStopsMatching() {
        let registry = RemoteForwardRegistry()
        registry.register(bindAddress: "127.0.0.1", boundPort: 8080, localHost: "localhost", localPort: 3000, counters: PortForwardCounters())
        registry.unregister(bindAddress: "127.0.0.1", boundPort: 8080)

        XCTAssertNil(registry.destination(listeningHost: "127.0.0.1", listeningPort: 8080))
        XCTAssertTrue(registry.isEmpty)
    }
}

final class PortForwardCountersTests: XCTestCase {
    func testCountsOpenAndClosed() {
        let counters = PortForwardCounters()
        counters.connectionOpened()
        counters.connectionOpened()
        counters.connectionClosed()

        let snapshot = counters.snapshot
        XCTAssertEqual(snapshot.activeConnections, 1)
        XCTAssertEqual(snapshot.totalConnections, 2)
    }

    /// A connection can be reported closed from both ends of the glue. A
    /// negative count in a status line reads as a broken tunnel rather than a
    /// broken counter.
    func testActiveCountNeverGoesNegative() {
        let counters = PortForwardCounters()
        counters.connectionOpened()
        counters.connectionClosed()
        counters.connectionClosed()
        XCTAssertEqual(counters.snapshot.activeConnections, 0)
        XCTAssertEqual(counters.snapshot.totalConnections, 1)
    }

    func testByteTotals() {
        let counters = PortForwardCounters()
        counters.add(sent: 100)
        counters.add(received: 250)
        counters.add(sent: 0)
        counters.add(received: -5)

        let snapshot = counters.snapshot
        XCTAssertEqual(snapshot.bytesSent, 100)
        XCTAssertEqual(snapshot.bytesReceived, 250)
    }
}
