import Foundation

/// How a directory is ordered and filtered before it is shown.
///
/// In `ssshCore` rather than in the view because both panes — remote and
/// local — have to agree, and because "directories first, then a locale-aware
/// name comparison" is a rule worth testing rather than a line of view code.
public struct DirectoryListingOptions: Hashable, Sendable {
    public enum SortKey: String, Hashable, Sendable, CaseIterable {
        case name
        case size
        case modified
        case kind
    }

    public var sortKey: SortKey
    public var ascending: Bool
    /// Dotfiles are hidden by default, as every file browser does — but this is
    /// an SSH client, and `.ssh`, `.bashrc` and `.config` are most of the
    /// reason someone opens one, so it is one toggle away and it is remembered.
    public var showsHidden: Bool
    /// Substring filter over names, case-insensitive unless the query has an
    /// uppercase letter.
    public var filter: String

    public init(sortKey: SortKey = .name, ascending: Bool = true, showsHidden: Bool = false, filter: String = "") {
        self.sortKey = sortKey
        self.ascending = ascending
        self.showsHidden = showsHidden
        self.filter = filter
    }

    public func apply(to entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var result = entries

        if !showsHidden {
            result = result.filter { !$0.name.hasPrefix(".") }
        }

        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let options: String.CompareOptions = query.contains(where: \.isUppercase)
                ? [.literal] : [.caseInsensitive, .literal]
            result = result.filter { $0.name.range(of: query, options: options) != nil }
        }

        result.sort { left, right in
            // Directories first whichever way the sort runs. Reversing that
            // with the sort direction scatters them through the list, and
            // nobody has ever wanted it.
            let leftIsDirectory = left.attributes.kind == .directory
            let rightIsDirectory = right.attributes.kind == .directory
            if leftIsDirectory != rightIsDirectory { return leftIsDirectory }
            // Two entries that tie all the way down have to compare equal in
            // both directions, or `sort` has no strict weak ordering to work
            // with. Names are unique within a directory, so this is the only
            // way a tie can happen.
            if left.name == right.name { return false }
            return compare(left, right) == ascending
        }
        return result
    }

    /// True when `left` sorts before `right` by the chosen key, ascending.
    private func compare(_ left: RemoteFileEntry, _ right: RemoteFileEntry) -> Bool {
        switch sortKey {
        case .name:
            return isNameOrdered(left.name, before: right.name)
        case .size:
            let leftSize = left.attributes.size ?? 0
            let rightSize = right.attributes.size ?? 0
            if leftSize != rightSize { return leftSize < rightSize }
            return isNameOrdered(left.name, before: right.name)
        case .modified:
            // A file the server gave no timestamp for sorts as oldest rather
            // than as "now", which is what `Date()` as a fallback would do.
            let leftDate = left.attributes.modifiedAt ?? .distantPast
            let rightDate = right.attributes.modifiedAt ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return isNameOrdered(left.name, before: right.name)
        case .kind:
            let leftKind = left.name.fileExtension
            let rightKind = right.name.fileExtension
            if leftKind != rightKind { return isNameOrdered(leftKind, before: rightKind) }
            return isNameOrdered(left.name, before: right.name)
        }
    }

    /// Compares the way a person reads names: `file2` before `file10`, and
    /// case ignored, which `<` on `String` does neither of.
    private func isNameOrdered(_ left: String, before right: String) -> Bool {
        let result = left.compare(right, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
        if result != .orderedSame { return result == .orderedAscending }
        // Identical apart from case is still two different files on a POSIX
        // server, so fall back to something total rather than leaving the sort
        // unstable.
        return left < right
    }
}

private extension String {
    /// The part after the last dot, lowercased. A leading dot is a hidden
    /// file's name, not an extension.
    var fileExtension: String {
        guard let index = dropFirst().lastIndex(of: "."), index != startIndex else { return "" }
        return String(self[self.index(after: index)...]).lowercased()
    }
}
