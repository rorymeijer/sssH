import XCTest
@testable import ssshCore

final class RemotePathTests: XCTestCase {
    func testLastComponent() {
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/b/c"), "c")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/b/"), "b")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a"), "a")
        XCTAssertEqual(RemotePath.lastComponent(of: "a"), "a")
        // The root's name is the root. "" is not something to show a person.
        XCTAssertEqual(RemotePath.lastComponent(of: "/"), "/")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent(of: "/a/b/c"), "/a/b")
        XCTAssertEqual(RemotePath.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        // A browser that can navigate above the root has nowhere to go.
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
    }

    func testAppending() {
        XCTAssertEqual(RemotePath.appending("b", to: "/a"), "/a/b")
        XCTAssertEqual(RemotePath.appending("b", to: "/"), "/b")
        XCTAssertEqual(RemotePath.appending("b", to: "/a/"), "/a/b")
        XCTAssertEqual(RemotePath.appending("", to: "/a"), "/a")
        // An absolute "component" replaces the path rather than being nested
        // under it, which is what `cd /etc` from anywhere means.
        XCTAssertEqual(RemotePath.appending("/etc", to: "/a"), "/etc")
    }

    /// Filenames that would break a `URL`-based implementation. These are all
    /// legal on a POSIX server.
    func testAwkwardNamesAreOrdinaryComponents() {
        XCTAssertEqual(RemotePath.appending("100% done", to: "/a"), "/a/100% done")
        XCTAssertEqual(RemotePath.appending("a#b", to: "/a"), "/a/a#b")
        XCTAssertEqual(RemotePath.appending("a b?c", to: "/"), "/a b?c")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/100% done"), "100% done")
    }

    func testNormalising() {
        XCTAssertEqual(RemotePath.normalising("/a/b/../c"), "/a/c")
        XCTAssertEqual(RemotePath.normalising("/a/./b"), "/a/b")
        XCTAssertEqual(RemotePath.normalising("/a//b"), "/a/b")
        XCTAssertEqual(RemotePath.normalising("/a/b/.."), "/a")
        // Above the root there is nothing; `..` there is not an error, it is
        // just the root again.
        XCTAssertEqual(RemotePath.normalising("/.."), "/")
        XCTAssertEqual(RemotePath.normalising("../x"), "../x")
        XCTAssertEqual(RemotePath.normalising(""), ".")
    }

    func testAncestors() {
        let ancestors = RemotePath.ancestors(of: "/var/log/nginx")
        XCTAssertEqual(ancestors.map(\.name), ["/", "var", "log", "nginx"])
        XCTAssertEqual(ancestors.map(\.path), ["/", "/var", "/var/log", "/var/log/nginx"])
        XCTAssertEqual(RemotePath.ancestors(of: "/").map(\.path), ["/"])
    }

    /// The check that stops a directory being copied into itself. A `hasPrefix`
    /// comparison says `/home/rory2` is inside `/home/rory`, and acting on that
    /// destroys data.
    func testDescendantComparesComponentsNotPrefixes() {
        XCTAssertTrue(RemotePath.isDescendant("/home/rory/a", of: "/home/rory"))
        XCTAssertTrue(RemotePath.isDescendant("/home/rory", of: "/home/rory"))
        XCTAssertFalse(RemotePath.isDescendant("/home/rory2", of: "/home/rory"))
        XCTAssertFalse(RemotePath.isDescendant("/home", of: "/home/rory"))
        XCTAssertTrue(RemotePath.isDescendant("/anything", of: "/"))
    }

    func testValidComponent() {
        XCTAssertTrue(RemotePath.isValidComponent("file.txt"))
        XCTAssertTrue(RemotePath.isValidComponent(".bashrc"))
        XCTAssertFalse(RemotePath.isValidComponent(""))
        XCTAssertFalse(RemotePath.isValidComponent("."))
        XCTAssertFalse(RemotePath.isValidComponent(".."))
        XCTAssertFalse(RemotePath.isValidComponent("a/b"))
        XCTAssertFalse(RemotePath.isValidComponent("a\0b"))
    }

    /// The check that decides whether a tunnel is reachable from the network.
    /// Wrong in the permissive direction it turns a personal tunnel into an
    /// open relay on a café Wi-Fi, so it matches exactly rather than by prefix.
    func testLoopbackAddresses() {
        XCTAssertTrue(RemotePath.isLoopbackAddress("127.0.0.1"))
        XCTAssertTrue(RemotePath.isLoopbackAddress("localhost"))
        XCTAssertTrue(RemotePath.isLoopbackAddress("LOCALHOST"))
        XCTAssertTrue(RemotePath.isLoopbackAddress("::1"))
        XCTAssertTrue(RemotePath.isLoopbackAddress("[::1]"))
        // The whole of 127.0.0.0/8 is loopback, not just .1.
        XCTAssertTrue(RemotePath.isLoopbackAddress("127.1.2.3"))
        XCTAssertTrue(RemotePath.isLoopbackAddress(" 127.0.0.1 "))

        XCTAssertFalse(RemotePath.isLoopbackAddress("0.0.0.0"))
        XCTAssertFalse(RemotePath.isLoopbackAddress(""))
        XCTAssertFalse(RemotePath.isLoopbackAddress("192.168.1.10"))
        XCTAssertFalse(RemotePath.isLoopbackAddress("::"))
        // A prefix match would call both of these loopback. They are not.
        XCTAssertFalse(RemotePath.isLoopbackAddress("127.0.0.1.example.com"))
        XCTAssertFalse(RemotePath.isLoopbackAddress("localhost.attacker.example"))
        XCTAssertFalse(RemotePath.isLoopbackAddress("1270.0.0.1"))
        XCTAssertFalse(RemotePath.isLoopbackAddress("127.0.0.256"))
    }

    func testUniqueName() {
        XCTAssertEqual(RemotePath.uniqueName("a.txt", avoiding: []), "a.txt")
        XCTAssertEqual(RemotePath.uniqueName("a.txt", avoiding: ["a.txt"]), "a 2.txt")
        XCTAssertEqual(RemotePath.uniqueName("a.txt", avoiding: ["a.txt", "a 2.txt"]), "a 3.txt")
        XCTAssertEqual(RemotePath.uniqueName("notes", avoiding: ["notes"]), "notes 2")
        // A leading dot is the whole name of a dotfile, not an extension.
        XCTAssertEqual(RemotePath.uniqueName(".bashrc", avoiding: [".bashrc"]), ".bashrc 2")
    }
}
