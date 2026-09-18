import Foundation

/// How well a candidate matches what has been typed. Higher is better; `nil`
/// means no match.
///
/// The tiers matter more than the numbers: an exact match must beat a prefix,
/// a prefix must beat a match at a word boundary, and a scattered subsequence
/// must come last so that `pw1` finding `prod-web-1` never pushes aside
/// something that really does contain the query.
public enum PaletteScoring {
    public static func score(_ text: String, query: String) -> Int? {
        let text = text.lowercased()
        let query = query.lowercased()

        guard !query.isEmpty else { return 0 }

        if text == query { return 100 }
        if text.hasPrefix(query) { return 80 }

        // A match at a word boundary: "web" should find "prod-web-1", and the
        // separators are the ones host names actually use.
        let separators = CharacterSet(charactersIn: " -_.@:/")
        if text.components(separatedBy: separators).contains(where: { $0.hasPrefix(query) }) {
            return 60
        }

        if text.contains(query) { return 40 }

        // Last resort: the query's characters in order, anywhere.
        return isSubsequence(query, of: text) ? 20 : nil
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
