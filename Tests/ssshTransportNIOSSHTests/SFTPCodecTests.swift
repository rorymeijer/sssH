import NIOCore
import XCTest
@testable import ssshCore
@testable import ssshTransportNIOSSH

/// Every expected byte string here was produced by Paramiko, an independent
/// SFTP implementation, rather than by this one. A round-trip test would pass
/// just as happily with the field order reversed; these fail if it is.
final class SFTPCodecTests: XCTestCase {
    private let allocator = ByteBufferAllocator()

    private func hex(_ buffer: ByteBuffer) -> String {
        buffer.readableBytesView.map { String(format: "%02x", $0) }.joined()
    }

    private func buffer(_ hex: String) -> ByteBuffer {
        var result = allocator.buffer(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.writeInteger(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func encoded(_ request: SFTPRequest, id: UInt32) -> String {
        hex(SFTPCodec.encode(request, id: id, allocator: allocator))
    }

    // MARK: - Attributes

    func testAttributeEncodingMatchesReference() {
        var sizeOnly = allocator.buffer(capacity: 16)
        sizeOnly.writeSFTPAttributes(RemoteFileAttributes(kind: .file, size: 1234))
        // Flags are SIZE only; the file-type bits are not sent because the
        // permission flag is not set.
        XCTAssertEqual(hex(sizeOnly), "0000000100000000000004d2")

        var full = allocator.buffer(capacity: 64)
        full.writeSFTPAttributes(RemoteFileAttributes(
            kind: .file,
            size: 0x1122_3344_5566_7788,
            permissions: POSIXPermissions(rawValue: 0o644),
            userID: 1000,
            groupID: 100,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            accessedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        XCTAssertEqual(hex(full), "0000000f1122334455667788000003e800000064000081a46553f1006553f101")

        // A directory's mode has to carry its type bits back, or a `setstat`
        // that only means to change permissions tells the server the thing is
        // now a regular file with mode 0.
        var directory = allocator.buffer(capacity: 16)
        directory.writeSFTPAttributes(RemoteFileAttributes(kind: .directory, permissions: POSIXPermissions(rawValue: 0o755)))
        XCTAssertEqual(hex(directory), "00000004000041ed")
    }

    func testAttributeDecodingMatchesReference() throws {
        var source = buffer("0000000f1122334455667788000003e800000064000081a46553f1006553f101")
        let attributes = try XCTUnwrap(source.readSFTPAttributes())
        XCTAssertEqual(attributes.size, 0x1122_3344_5566_7788)
        XCTAssertEqual(attributes.userID, 1000)
        XCTAssertEqual(attributes.groupID, 100)
        XCTAssertEqual(attributes.permissions?.rawValue, 0o644)
        XCTAssertEqual(attributes.kind, .file)
        XCTAssertEqual(attributes.accessedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(attributes.modifiedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(source.readableBytes, 0)
    }

    func testAbsentPermissionsMeanUnknownKindRatherThanFile() throws {
        var source = buffer("0000000100000000000004d2")
        let attributes = try XCTUnwrap(source.readSFTPAttributes())
        XCTAssertEqual(attributes.kind, .other)
        XCTAssertNil(attributes.permissions)
    }

    func testPermissionsKeepOnlyTheLowTwelveBits() {
        XCTAssertEqual(POSIXPermissions(rawValue: 0o100_644).rawValue, 0o644)
        XCTAssertEqual(POSIXPermissions(rawValue: 0o755).description, "rwxr-xr-x")
        XCTAssertEqual(POSIXPermissions(rawValue: 0o640).description, "rw-r-----")
    }

    // MARK: - Requests

    func testRequestEncodingMatchesReference() {
        XCTAssertEqual(
            encoded(.open(path: "/tmp/a.txt", flags: .read, attributes: nil), id: 1),
            "0000001b03000000010000000a2f746d702f612e7478740000000100000000"
        )
        XCTAssertEqual(
            encoded(.read(handle: buffer("0102"), offset: 4096, length: 32768), id: 7),
            "000000170500000007000000020102000000000000100000008000"
        )
        XCTAssertEqual(
            encoded(.write(handle: buffer("aa"), offset: 0, data: buffer("6869")), id: 9),
            "00000018060000000900000001aa0000000000000000000000026869"
        )
        XCTAssertEqual(encoded(.opendir(path: "/var/log"), id: 2), "000000110b00000002000000082f7661722f6c6f67")
        XCTAssertEqual(encoded(.readdir(handle: buffer("dead")), id: 3), "0000000b0c0000000300000002dead")
        XCTAssertEqual(encoded(.realpath(path: "."), id: 4), "0000000a1000000004000000012e")
        XCTAssertEqual(encoded(.rename(from: "/a", to: "/b"), id: 5), "000000111200000005000000022f61000000022f62")
        XCTAssertEqual(encoded(.rmdir(path: "/d"), id: 6), "0000000b0f00000006000000022f64")
        XCTAssertEqual(encoded(.close(handle: buffer("01")), id: 8), "0000000a04000000080000000101")
        XCTAssertEqual(encoded(.lstat(path: "/x"), id: 10), "0000000b070000000a000000022f78")
        XCTAssertEqual(encoded(.readlink(path: "/l"), id: 11), "0000000b130000000b000000022f6c")
    }

    func testInitializeMatchesReference() {
        XCTAssertEqual(hex(SFTPCodec.encodeInitialize(version: 3, allocator: allocator)), "000000050100000003")
    }

    /// The draft says `linkpath` then `targetpath`. OpenSSH's server reads
    /// them the other way round, and every client — Paramiko included —
    /// matches the server rather than the document.
    func testSymlinkSendsTargetBeforeLinkPath() {
        let encodedSymlink = encoded(.symlink(linkPath: "/link", target: "/target"), id: 12)
        let target = "00000007" + Array("/target".utf8).map { String(format: "%02x", $0) }.joined()
        let link = "00000005" + Array("/link".utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(encodedSymlink.hasSuffix(target + link), encodedSymlink)
    }

    func testOpenFlagsMapToProtocolValues() {
        XCTAssertEqual(SFTPOpenFlags(.read).rawValue, 1)
        XCTAssertEqual(SFTPOpenFlags(.write).rawValue, 2)
        XCTAssertEqual(SFTPOpenFlags(.append).rawValue, 4)
        XCTAssertEqual(SFTPOpenFlags(.create).rawValue, 8)
        XCTAssertEqual(SFTPOpenFlags(.truncate).rawValue, 16)
        XCTAssertEqual(SFTPOpenFlags(.exclusive).rawValue, 32)
        XCTAssertEqual(SFTPOpenFlags([.write, .create, .truncate]).rawValue, 26)
    }

    // MARK: - Responses

    private func decodeReply(_ hexString: String) throws -> (id: UInt32, response: SFTPResponse) {
        var packet = buffer(hexString)
        let length: UInt32 = try XCTUnwrap(packet.readInteger())
        XCTAssertEqual(Int(length), packet.readableBytes)
        let rawType: UInt8 = try XCTUnwrap(packet.readInteger())
        let type = try XCTUnwrap(SFTPPacketType(rawValue: rawType))
        let id: UInt32 = try XCTUnwrap(packet.readInteger())
        return (id, try SFTPCodec.decodeResponse(type: type, from: &packet))
    }

    func testStatusDecoding() throws {
        guard case .status(let ok) = try decodeReply("000000116500000001000000000000000000000000").response else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(ok.code, .ok)
        // An empty message is no message, not an empty one.
        XCTAssertNil(ok.message)
        XCTAssertNil(ok.asError(path: "/x"))

        guard case .status(let eof) = try decodeReply("000000116500000002000000010000000000000000").response else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(eof.code, .endOfFile)
        // End of file is how the protocol says "that is all", so it must not
        // surface as an error.
        XCTAssertNil(eof.asError(path: nil))

        guard case .status(let missing) = try decodeReply("0000001d6500000003000000020000000c4e6f20737563682066696c6500000000").response else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(missing.message, "No such file")
        XCTAssertEqual(missing.asError(path: "/gone"), .noSuchFile(path: "/gone", serverMessage: "No such file"))

        guard case .status(let denied) = try decodeReply("00000022650000000400000003000000115065726d697373696f6e2064656e69656400000000").response else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(denied.asError(path: "/root"), .permissionDenied(path: "/root", serverMessage: "Permission denied"))
    }

    /// Version 3 added the message and language fields, and servers still ship
    /// that omit them. A parser that requires them turns a working server into
    /// a protocol error.
    func testStatusWithoutMessageFields() throws {
        guard case .status(let status) = try decodeReply("00000009650000000500000004").response else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(status.code, .failure)
        XCTAssertNil(status.message)
    }

    func testHandleAndDataDecoding() throws {
        guard case .handle(let handle) = try decodeReply("0000000c660000000600000003000102").response else {
            return XCTFail("expected a handle")
        }
        XCTAssertEqual(Array(handle.readableBytesView), [0x00, 0x01, 0x02])

        guard case .data(var data) = try decodeReply("0000000e67000000070000000568656c6c6f").response else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(data.readString(length: data.readableBytes), "hello")
    }

    func testNameDecodingIncludingTheLongNameFallback() throws {
        let reference = "000000896800000008000000020000000a726561646d652e7478740000002a2d72" +
            "772d722d2d722d2d203120752075203132204a616e20312030303a303020726561" +
            "646d652e74787400000005000000000000000c000081a4000000037375620000" +
            "002564727778722d78722d782032207520752034303936204a616e2031203030" +
            "3a30302073756200000000"
        guard case .name(let entries) = try decodeReply(reference).response else {
            return XCTFail("expected names")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].filename, "readme.txt")
        XCTAssertEqual(entries[0].attributes.kind, .file)
        XCTAssertEqual(entries[0].attributes.size, 12)
        XCTAssertEqual(entries[0].attributes.permissions?.rawValue, 0o644)

        // The second entry carries no attribute flags at all, so its type can
        // only come from the `ls -l` line — which is exactly what a server
        // that omits permissions leaves you with.
        XCTAssertEqual(entries[1].filename, "sub")
        XCTAssertEqual(entries[1].attributes.kind, .directory)
        XCTAssertNil(entries[1].attributes.permissions)
    }

    // MARK: - Malformed input

    func testTruncatedRepliesAreRejectedRatherThanTrapping() {
        var short = buffer("0000")
        XCTAssertNil(short.readSFTPBytes())

        // A length field says 4 GB and the buffer holds two bytes. Believing
        // it is how a parser turns into an allocation the size of the machine.
        var lying = buffer("ffffffff0102")
        XCTAssertNil(lying.readSFTPBytes())

        var truncatedAttributes = buffer("0000000111223344")
        XCTAssertNil(truncatedAttributes.readSFTPAttributes())
    }

    func testAResponseTypeThatIsReallyARequestIsRejected() {
        var packet = buffer("00000000")
        XCTAssertThrowsError(try SFTPCodec.decodeResponse(type: .open, from: &packet)) { error in
            guard case SFTPError.protocolViolation = error else {
                return XCTFail("expected a protocol violation, got \(error)")
            }
        }
    }

    func testNonUTF8FilenamesSurviveRatherThanDisappearing() {
        // POSIX filenames are bytes. A browser that drops the ones that are
        // not valid UTF-8 hides files that exist.
        var packet = allocator.buffer(capacity: 16)
        packet.writeInteger(UInt32(3))
        packet.writeBytes([0x61, 0xFF, 0x62])
        XCTAssertNotNil(packet.readSFTPString())
    }

    func testRetryAdviceDistinguishesTheCasesWorthRetrying() {
        XCTAssertTrue(SFTPError.connectionLost.isWorthRetrying)
        XCTAssertFalse(SFTPError.permissionDenied(path: "/x", serverMessage: nil).isWorthRetrying)
        XCTAssertFalse(SFTPError.noSuchFile(path: "/x", serverMessage: nil).isWorthRetrying)
    }
}
