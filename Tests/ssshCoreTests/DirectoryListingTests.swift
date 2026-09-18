import XCTest
@testable import ssshCore

final class DirectoryListingTests: XCTestCase {
    private func entry(_ name: String, kind: RemoteFileAttributes.Kind = .file, size: UInt64? = nil, modified: Date? = nil) -> RemoteFileEntry {
        RemoteFileEntry(name: name, attributes: RemoteFileAttributes(kind: kind, size: size, modifiedAt: modified))
    }

    private var sample: [RemoteFileEntry] {
        [
            entry("file10.log", size: 10, modified: Date(timeIntervalSince1970: 300)),
            entry("File2.log", size: 200, modified: Date(timeIntervalSince1970: 100)),
            entry(".hidden", size: 1),
            entry("src", kind: .directory),
            entry("Applications", kind: .directory),
            entry("notes.txt", size: 50),
            entry("nosize.bin"),
        ]
    }

    func testDirectoriesComeFirstInBothDirections() {
        var options = DirectoryListingOptions()
        XCTAssertEqual(options.apply(to: sample).prefix(2).map(\.name), ["Applications", "src"])

        options.ascending = false
        // Reversing the sort must not scatter directories through the list.
        XCTAssertEqual(options.apply(to: sample).prefix(2).map(\.name).sorted(), ["Applications", "src"])
    }

    /// `file2` before `file10`, and case ignored — neither of which `<` on
    /// `String` does.
    func testNameSortIsNaturalAndCaseInsensitive() {
        let options = DirectoryListingOptions()
        let names = options.apply(to: sample).filter { $0.name.hasSuffix(".log") }.map(\.name)
        XCTAssertEqual(names, ["File2.log", "file10.log"])
    }

    func testHiddenFilesAreHiddenUntilAskedFor() {
        var options = DirectoryListingOptions()
        XCTAssertFalse(options.apply(to: sample).contains { $0.name == ".hidden" })
        options.showsHidden = true
        XCTAssertTrue(options.apply(to: sample).contains { $0.name == ".hidden" })
    }

    func testFilterIsSmartCase() {
        var options = DirectoryListingOptions(filter: "log")
        XCTAssertEqual(options.apply(to: sample).count, 2)
        options.filter = "Log"
        // An uppercase letter in the query asks for a case-sensitive match, so
        // `file10.log` and `File2.log` both drop out.
        XCTAssertEqual(options.apply(to: sample).count, 0)
    }

    func testSizeSortPutsUnknownSizesFirstAndBreaksTiesByName() {
        let options = DirectoryListingOptions(sortKey: .size)
        let files = options.apply(to: sample).filter { $0.attributes.kind != .directory }
        XCTAssertEqual(files.first?.name, "nosize.bin")
        XCTAssertEqual(files.map(\.name), ["nosize.bin", "file10.log", "notes.txt", "File2.log"])
    }

    /// A file the server gave no timestamp for sorts as oldest, not as now —
    /// which is what a `Date()` fallback would do, putting unknown files at the
    /// top of a newest-first list.
    func testModifiedSortTreatsUnknownAsOldest() {
        let options = DirectoryListingOptions(sortKey: .modified, ascending: false)
        let files = options.apply(to: sample).filter { $0.attributes.kind != .directory }
        XCTAssertEqual(files.first?.name, "file10.log")
        XCTAssertEqual(files.last?.name, "nosize.bin")
    }

    func testSortIsTotalSoItCannotTrap() {
        // Two entries identical in every sorted field. A comparator that says
        // "before" in both directions is not a strict weak ordering, and
        // `sort` is entitled to do anything at all with one.
        let duplicates = [entry("same", size: 1), entry("same", size: 1)]
        for key in DirectoryListingOptions.SortKey.allCases {
            for ascending in [true, false] {
                let options = DirectoryListingOptions(sortKey: key, ascending: ascending)
                XCTAssertEqual(options.apply(to: duplicates).count, 2)
            }
        }
    }
}
