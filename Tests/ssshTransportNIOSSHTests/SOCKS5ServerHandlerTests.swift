import NIOCore
import NIOEmbedded
import Logging
import XCTest
@testable import ssshTransportNIOSSH

/// The request byte strings here were captured from PySocks, an independent
/// SOCKS5 client, connecting through a recording socket. The success reply is
/// the one this handler writes, and PySocks accepted it and went on to use the
/// tunnel — so both directions are checked against something that is not this
/// implementation.
final class SOCKS5ServerHandlerTests: XCTestCase {
    private let logger = Logger(label: "test")

    /// `VER REP RSV ATYP BND.ADDR BND.PORT`, with the bound address reported
    /// as 0.0.0.0:0. The real one is on the SSH server and this client never
    /// learns it.
    private static func reply(_ code: UInt8) -> String {
        "05" + String(format: "%02x", code) + "0001" + "00000000" + "0000"
    }

    private static let successReply = reply(0x00)

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private func hex(_ buffer: ByteBuffer) -> String {
        buffer.readableBytesView.map { String(format: "%02x", $0) }.joined()
    }

    /// Drives a handler and records what it was asked to connect to.
    private final class Recorder {
        var requests: [(host: String, port: Int)] = []
        var shouldSucceed = true
        var confirmed = false
    }

    private func makeChannel(_ recorder: Recorder) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        let handler = SOCKS5ServerHandler(logger: logger) { channel, host, port, confirm in
            recorder.requests.append((host, port))
            guard recorder.shouldSucceed else {
                return channel.eventLoop.makeFailedFuture(SSHChannelError.inappropriateChannelType)
            }
            return confirm().map { recorder.confirmed = true }
        }
        try channel.pipeline.syncOperations.addHandler(handler)
        return channel
    }

    private func write(_ hex: String, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeBytes(bytes(hex))
        try channel.writeInbound(buffer)
    }

    private func readAllOutbound(_ channel: EmbeddedChannel) throws -> String {
        var combined = ""
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            combined += hex(buffer)
        }
        return combined
    }

    // MARK: - Captured from PySocks

    func testDomainNameRequest() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)

        // `05 01 00` — version 5, one method, "no authentication".
        try write("050100", to: channel)
        XCTAssertEqual(try readAllOutbound(channel), "0500")

        // CONNECT to example.internal:8080, as a domain name.
        try write("05010003106578616d706c652e696e7465726e616c1f90", to: channel)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.host, "example.internal")
        XCTAssertEqual(recorder.requests.first?.port, 8080)
        XCTAssertTrue(recorder.confirmed)
        // The exact bytes PySocks accepted: success, IPv4, 0.0.0.0:0.
        XCTAssertEqual(try readAllOutbound(channel), Self.successReply)

        _ = try channel.finish()
    }

    func testIPv4Request() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)
        try write("050100", to: channel)
        _ = try readAllOutbound(channel)
        try write("050100015db8d82201bb", to: channel)
        XCTAssertEqual(recorder.requests.first?.host, "93.184.216.34")
        XCTAssertEqual(recorder.requests.first?.port, 443)
        _ = try channel.finish()
    }

    func testIPv6Request() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)
        try write("050100", to: channel)
        _ = try readAllOutbound(channel)
        try write("0501000426062800022000010248189325c819460050", to: channel)
        XCTAssertEqual(recorder.requests.first?.host, "2606:2800:220:1:248:1893:25c8:1946")
        XCTAssertEqual(recorder.requests.first?.port, 80)
        _ = try channel.finish()
    }

    // MARK: - Split and malformed input

    /// The case a per-read parser gets wrong. A greeting and a request can
    /// arrive one byte at a time, and they do on a loaded machine.
    func testRequestSplitAcrossEveryByteStillParses() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)

        for byte in bytes("050100") + bytes("05010003106578616d706c652e696e7465726e616c1f90") {
            var buffer = channel.allocator.buffer(capacity: 1)
            buffer.writeInteger(byte)
            try channel.writeInbound(buffer)
        }

        XCTAssertEqual(recorder.requests.first?.host, "example.internal")
        XCTAssertEqual(recorder.requests.first?.port, 8080)
        _ = try channel.finish()
    }

    func testClientThatRefusesNoAuthenticationIsToldSoAndClosed() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)

        // One method, 0x02 — username and password. This proxy offers none.
        try write("050102", to: channel)
        XCTAssertEqual(try readAllOutbound(channel), "05ff")
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertFalse(channel.isActive)
        _ = try? channel.finish()
    }

    /// `BIND` and `UDP ASSOCIATE` cannot be carried over a `direct-tcpip`
    /// channel. Refusing in the protocol's own terms is clearer than accepting
    /// and failing later.
    func testBindIsRefusedWithCommandNotSupported() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)
        try write("050100", to: channel)
        _ = try readAllOutbound(channel)

        // Command 0x02 is BIND.
        try write("050200015db8d82201bb", to: channel)
        XCTAssertEqual(try readAllOutbound(channel), Self.reply(0x07))
        XCTAssertTrue(recorder.requests.isEmpty)
        _ = try? channel.finish()
    }

    func testUnknownAddressTypeIsRefused() throws {
        let recorder = Recorder()
        let channel = try makeChannel(recorder)
        try write("050100", to: channel)
        _ = try readAllOutbound(channel)
        try write("050100090102", to: channel)
        XCTAssertEqual(try readAllOutbound(channel), Self.reply(0x08))
        _ = try? channel.finish()
    }

    /// A refused destination has to come back as a SOCKS reply, not as a
    /// silently dropped connection: the client is entitled to know the
    /// difference between "cannot reach it" and "the proxy is broken".
    func testRefusedDestinationRepliesHostUnreachable() throws {
        let recorder = Recorder()
        recorder.shouldSucceed = false
        let channel = try makeChannel(recorder)
        try write("050100", to: channel)
        _ = try readAllOutbound(channel)
        try write("050100015db8d82201bb", to: channel)
        XCTAssertEqual(try readAllOutbound(channel), Self.reply(0x04))
        _ = try? channel.finish()
    }

    /// Bytes sent in the same packet as the request belong to the tunnel, and
    /// losing them is what makes a pipelined request through the proxy hang.
    func testBytesAfterTheRequestAreReplayed() throws {
        final class Collector: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            var received: [UInt8] = []
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                received.append(contentsOf: unwrapInboundIn(data).readableBytesView)
            }
        }

        let recorder = Recorder()
        let channel = try makeChannel(recorder)
        let collector = Collector()
        try channel.pipeline.syncOperations.addHandler(collector)

        try write("050100", to: channel)
        _ = try readAllOutbound(channel)
        // Request, followed immediately by "GET /".
        try write("050100015db8d82201bb" + "474554202f", to: channel)

        XCTAssertEqual(collector.received, Array("GET /".utf8))
        _ = try channel.finish()
    }
}
