import Foundation
import XCTest
@testable import ssshCrypto

/// The reader parses attacker-controlled input, so the point of these is that
/// it returns `nil` rather than trapping or over-reading.
final class SSHWireTests: XCTestCase {
    func testReadsStringsAndIntegers() {
        var writer = SSHWireWriter()
        writer.writeUInt32(0xDEADBEEF)
        writer.writeString("hello")
        writer.writeString([1, 2, 3])

        var reader = SSHWireReader(writer.bytes)
        XCTAssertEqual(reader.readUInt32(), 0xDEADBEEF)
        XCTAssertEqual(reader.readStringAsText(), "hello")
        XCTAssertEqual(reader.readString(), [1, 2, 3])
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadingPastTheEndReturnsNil() {
        var reader = SSHWireReader([0, 0, 0])
        XCTAssertNil(reader.readUInt32())
        XCTAssertNil(reader.readString())
        XCTAssertNil(reader.readBytes(4))
        XCTAssertEqual(reader.readBytes(3), [0, 0, 0])
    }

    func testAnAbsurdLengthFieldIsRejectedRatherThanAllocated() {
        // A corrupt file claiming a 4 GB string must not cause an allocation
        // attempt or a trap.
        var reader = SSHWireReader([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3])
        XCTAssertNil(reader.readString())
    }

    func testMPIntStripsSignPadding() {
        var writer = SSHWireWriter()
        writer.writeMPInt([0x80, 0x01])     // top bit set: gains a leading zero
        writer.writeMPInt([0x00, 0x7F])     // already positive: loses its zero
        writer.writeMPInt([])               // zero

        // The encoding grew the sign byte...
        XCTAssertEqual(Array(writer.bytes[0..<4]), [0, 0, 0, 3])
        XCTAssertEqual(Array(writer.bytes[4..<7]), [0x00, 0x80, 0x01])

        // ...and reading gives back the unsigned magnitude.
        var reader = SSHWireReader(writer.bytes)
        XCTAssertEqual(reader.readMPInt(), [0x80, 0x01])
        XCTAssertEqual(reader.readMPInt(), [0x7F])
        XCTAssertEqual(reader.readMPInt(), [])
    }

    func testReadAllRemaining() {
        var reader = SSHWireReader([1, 2, 3, 4])
        _ = reader.readBytes(1)
        XCTAssertEqual(reader.readAllRemaining(), [2, 3, 4])
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(reader.readAllRemaining(), [])
    }
}
