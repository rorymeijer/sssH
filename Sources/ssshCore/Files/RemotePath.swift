import Foundation

/// POSIX path arithmetic for the remote side.
///
/// `URL` is not usable here. It percent-encodes, it has opinions about what a
/// path component may contain, and on a POSIX server a filename is an
/// arbitrary byte string that may well contain a `%`, a `#` or a newline.
/// Every one of those round-trips through `URL` wrong, and the failure shows
/// up as "the file browser cannot open that one directory".
public enum RemotePath {
    public static let separator: Character = "/"
    public static let root = "/"

    public static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    /// The last component, without a trailing slash. The root's name is the
    /// root itself, because "" is not something to show a person.
    public static func lastComponent(of path: String) -> String {
        let trimmed = trimmingTrailingSeparators(path)
        guard !trimmed.isEmpty else { return root }
        guard let index = trimmed.lastIndex(of: separator) else { return trimmed }
        return String(trimmed[trimmed.index(after: index)...])
    }

    /// The containing directory. The root's parent is the root: a browser that
    /// can navigate above `/` has nowhere to go.
    public static func parent(of path: String) -> String {
        let trimmed = trimmingTrailingSeparators(path)
        guard !trimmed.isEmpty else { return root }
        guard let index = trimmed.lastIndex(of: separator) else { return "." }
        let parent = String(trimmed[trimmed.startIndex..<index])
        return parent.isEmpty ? root : parent
    }

    public static func appending(_ component: String, to path: String) -> String {
        guard !component.isEmpty else { return path }
        if isAbsolute(component) { return component }
        let base = trimmingTrailingSeparators(path)
        return base.isEmpty ? "\(root)\(component)" : "\(base)\(separator)\(component)"
    }

    /// Resolves `.` and `..` textually, without asking the server.
    ///
    /// Textual resolution is wrong in the presence of symlinks — `a/b/..` is
    /// not `a` when `b` is a link — which is why navigation uses the server's
    /// own `realpath` and this is only used for display and for building a
    /// path to ask about.
    public static func normalising(_ path: String) -> String {
        let absolute = isAbsolute(path)
        var components: [String] = []
        for component in path.split(separator: separator, omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !absolute {
                    components.append("..")
                }
            default:
                components.append(String(component))
            }
        }
        let joined = components.joined(separator: String(separator))
        if absolute { return joined.isEmpty ? root : "\(root)\(joined)" }
        return joined.isEmpty ? "." : joined
    }

    /// Every directory from the root down to `path`, for a breadcrumb bar.
    public static func ancestors(of path: String) -> [(name: String, path: String)] {
        let normalised = normalising(path)
        guard isAbsolute(normalised) else { return [(normalised, normalised)] }

        var result: [(name: String, path: String)] = [(root, root)]
        var current = ""
        for component in normalised.split(separator: separator, omittingEmptySubsequences: true) {
            current += "\(separator)\(component)"
            result.append((String(component), current))
        }
        return result
    }

    /// Whether `path` is `ancestor` or sits underneath it.
    ///
    /// Compared component-wise rather than with `hasPrefix`, because
    /// `/home/rory2` starts with `/home/rory` and is not inside it. Copying a
    /// directory into itself is the operation this prevents, and it destroys
    /// data when it is allowed through.
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let path = normalising(path)
        let ancestor = normalising(ancestor)
        if path == ancestor { return true }
        if ancestor == root { return isAbsolute(path) }
        return path.hasPrefix(ancestor + String(separator))
    }

    /// Whether a name can be used as a single path component.
    public static func isValidComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains(separator)
            && !name.contains("\0")
    }

    /// A name that does not collide with anything in `existing`, by adding
    /// " 2", " 3" and so on before the extension.
    public static func uniqueName(_ name: String, avoiding existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }

        // A leading dot is the whole name of a dotfile, not an extension, so
        // `.bashrc` must become `.bashrc 2` rather than ` 2.bashrc`.
        let dotIndex = name.dropFirst().lastIndex(of: ".").map { name.index($0, offsetBy: 0) }
        let stem = dotIndex.map { String(name[name.startIndex..<$0]) } ?? name
        let suffix = dotIndex.map { String(name[$0...]) } ?? ""

        var counter = 2
        while true {
            let candidate = "\(stem) \(counter)\(suffix)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
            // A directory with thousands of collisions is pathological, and a
            // loop that cannot end is worse than a name with a UUID in it.
            if counter > 9999 { return "\(stem) \(UUID().uuidString)\(suffix)" }
        }
    }

    /// Whether an address means "this machine only".
    ///
    /// Not path arithmetic, but it lives with it for want of a better home,
    /// and it is the check that decides whether a tunnel is reachable from the
    /// network. Wrong in the permissive direction it turns a personal tunnel
    /// into an open relay, so the list is exact rather than a prefix match:
    /// `127.0.0.1` is loopback and `127.0.0.1.example.com` is not.
    public static func isLoopbackAddress(_ address: String) -> Bool {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        if address == "localhost" || address == "::1" || address == "[::1]" { return true }
        // The whole of 127.0.0.0/8 is loopback, not just 127.0.0.1.
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }

    private static func trimmingTrailingSeparators(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1, result.last == separator {
            result = result.dropLast()
        }
        return result == "/" ? "" : String(result)
    }
}
