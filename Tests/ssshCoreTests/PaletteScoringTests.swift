import Foundation
import XCTest
@testable import ssshCore

/// Ranking for the command palette.
///
/// Lives in `ssshCore` rather than the app because it is pure string logic and
/// because ranking is where a palette is won or lost: a list in storage order
/// is a list people stop using.
final class PaletteScoringTests: XCTestCase {
    private func rank(_ candidates: [String], for query: String) -> [String] {
        candidates
            .compactMap { text -> (String, Int)? in
                guard let score = PaletteScoring.score(text, query: query) else { return nil }
                return (text, score)
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .map(\.0)
    }

    func testExactMatchBeatsEverything() {
        XCTAssertEqual(rank(["prod", "prod-web-1", "reproduce"], for: "prod").first, "prod")
    }

    func testPrefixBeatsWordBoundaryBeatsSubstring() throws {
        let ranked = rank(["prod-web-1", "eu-prod-db", "reproduce-bug"], for: "prod")
        // Prefix, then a match at a word boundary, then a bare substring.
        XCTAssertEqual(ranked, ["prod-web-1", "eu-prod-db", "reproduce-bug"])
    }

    func testWordBoundaryHandlesTheSeparatorsHostsActuallyUse() {
        for candidate in ["prod-web-1", "prod_web_1", "prod.web.1", "root@web", "host:web"] {
            XCTAssertNotNil(PaletteScoring.score(candidate, query: "web"), candidate)
            XCTAssertGreaterThanOrEqual(
                PaletteScoring.score(candidate, query: "web") ?? 0, 60,
                "\(candidate) should match at a word boundary, not merely as a substring"
            )
        }
    }

    func testInitialsMatchAsASubsequence() {
        // The thing people reach for once they trust the palette.
        XCTAssertNotNil(PaletteScoring.score("prod-web-1", query: "pw1"))
        XCTAssertNotNil(PaletteScoring.score("staging-database", query: "sdb"))
    }

    func testSubsequenceScoresLowestSoItNeverOutranksARealMatch() throws {
        let subsequence = try XCTUnwrap(PaletteScoring.score("prod-web-1", query: "pw1"))
        let substring = try XCTUnwrap(PaletteScoring.score("reproduce", query: "prod"))
        XCTAssertLessThan(subsequence, substring)
    }

    func testNonMatchesAreRejected() {
        XCTAssertNil(PaletteScoring.score("prod-web-1", query: "zzz"))
        // Right characters, wrong order: a subsequence is ordered.
        XCTAssertNil(PaletteScoring.score("abc", query: "cb"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            PaletteScoring.score("PROD-Web-1", query: "prod"),
            PaletteScoring.score("prod-web-1", query: "PROD")
        )
    }
}
