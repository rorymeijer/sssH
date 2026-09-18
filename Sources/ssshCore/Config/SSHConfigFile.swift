import Foundation

/// A parsed `~/.ssh/config`.
///
/// Parsed rather than interpreted: this type says what the file contains, and
/// the importer decides what sssh can do with it. Keeping those apart is what
/// lets the parser be checked against `ssh -G` without also having to agree
/// about which settings the app supports.
public struct SSHConfigFile: Hashable, Sendable {
    public struct Setting: Hashable, Sendable {
        /// As written, so a warning can quote it back. Compared
        /// case-insensitively, as OpenSSH does.
        public var keyword: String
        public var value: String
        public var lineNumber: Int

        public init(keyword: String, value: String, lineNumber: Int) {
            self.keyword = keyword
            self.value = value
            self.lineNumber = lineNumber
        }

        public func matches(_ name: String) -> Bool {
            keyword.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    public enum Scope: Hashable, Sendable {
        /// Settings before any `Host` or `Match` line. They apply to
        /// everything, and — because OpenSSH takes the first value it sees —
        /// they beat everything written later.
        case global
        /// `Host pattern [pattern ...]`
        case host(patterns: [SSHConfigPattern])
        /// `Match ...`. Only the criteria sssh can evaluate are kept; see
        /// ``MatchCriterion``.
        case match(criteria: [MatchCriterion])
    }

    public enum MatchCriterion: Hashable, Sendable {
        case all
        case host([SSHConfigPattern])
        case originalHost([SSHConfigPattern])
        case user([SSHConfigPattern])
        case localUser([SSHConfigPattern])
        /// `Match exec "..."` and anything else this client will not evaluate.
        ///
        /// Never run. `exec` asks the config file to run a shell command in
        /// order to decide whether a block applies, and a file that arrives by
        /// import or by sync is not something to execute. A block containing
        /// one is treated as never matching, and the import says so.
        case unevaluatable(keyword: String, value: String)
    }

    public struct Block: Hashable, Sendable {
        public var scope: Scope
        public var settings: [Setting]
        public var lineNumber: Int

        public init(scope: Scope, settings: [Setting] = [], lineNumber: Int = 0) {
            self.scope = scope
            self.settings = settings
            self.lineNumber = lineNumber
        }
    }

    public var blocks: [Block]
    /// `Include` lines, in order, unresolved. Resolving them needs the file
    /// system, which the parser deliberately does not touch.
    public var includes: [Setting]
    /// Lines the parser could not make sense of, kept so the import can say
    /// which ones it ignored instead of pretending the file was clean.
    public var unparsedLines: [Setting]

    public init(blocks: [Block] = [], includes: [Setting] = [], unparsedLines: [Setting] = []) {
        self.blocks = blocks
        self.includes = includes
        self.unparsedLines = unparsedLines
    }

    /// Every alias that names exactly one host — a `Host` pattern with no
    /// wildcard and no negation.
    ///
    /// These are the ones worth importing. `Host *.example.com` configures a
    /// family of hosts without naming any of them, and inventing a host called
    /// `*.example.com` would be a saved connection that cannot connect.
    public var importableAliases: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for block in blocks {
            guard case .host(let patterns) = block.scope else { continue }
            for pattern in patterns where pattern.isLiteral {
                guard seen.insert(pattern.text).inserted else { continue }
                result.append(pattern.text)
            }
        }
        return result
    }
}

/// One `Host` or `Match` pattern.
///
/// OpenSSH's patterns are `*`, `?` and a leading `!` for negation — not
/// regular expressions and not shell globs, in that `*` crosses dots and
/// there is no character class.
public struct SSHConfigPattern: Hashable, Sendable {
    /// The pattern without its negation mark.
    public var text: String
    public var isNegated: Bool

    public init(_ raw: String) {
        if raw.hasPrefix("!") {
            isNegated = true
            text = String(raw.dropFirst())
        } else {
            isNegated = false
            text = raw
        }
    }

    /// True when this names one host rather than a family of them.
    public var isLiteral: Bool {
        !isNegated && !text.isEmpty && !text.contains("*") && !text.contains("?")
    }

    public func matches(_ candidate: String) -> Bool {
        Self.matches(candidate, pattern: text)
    }

    /// Glob matching with `*` and `?`, iterative rather than recursive.
    ///
    /// A recursive implementation is shorter and has a well-known worst case:
    /// a pattern like `a*a*a*a*b` against a long string of `a`s takes
    /// exponential time. A config file is not usually adversarial, but it can
    /// arrive by sync, and a file browser that hangs on one is not a trade
    /// worth making.
    public static func matches(_ candidate: String, pattern: String) -> Bool {
        let text = Array(candidate)
        let glob = Array(pattern)

        var textIndex = 0
        var globIndex = 0
        /// Where to resume if the current `*` turns out to have matched too
        /// little.
        var starIndex = -1
        var matchIndex = 0

        while textIndex < text.count {
            if globIndex < glob.count, glob[globIndex] == "?" || glob[globIndex] == text[textIndex] {
                textIndex += 1
                globIndex += 1
            } else if globIndex < glob.count, glob[globIndex] == "*" {
                starIndex = globIndex
                matchIndex = textIndex
                globIndex += 1
            } else if starIndex != -1 {
                globIndex = starIndex + 1
                matchIndex += 1
                textIndex = matchIndex
            } else {
                return false
            }
        }

        while globIndex < glob.count, glob[globIndex] == "*" {
            globIndex += 1
        }
        return globIndex == glob.count
    }
}

public extension Array where Element == SSHConfigPattern {
    /// A host matches a pattern list when at least one positive pattern
    /// matches and no negative one does. A list of only negations matches
    /// nothing, which is what OpenSSH does.
    func matchesHost(_ host: String) -> Bool {
        var matchedPositive = false
        for pattern in self {
            guard pattern.matches(host) else { continue }
            if pattern.isNegated { return false }
            matchedPositive = true
        }
        return matchedPositive
    }
}
