import Foundation

/// Reads OpenSSH's client configuration format.
///
/// The format looks simpler than it is. Four things trip up every naive
/// parser, and all four appear in real files:
///
/// - **`Keyword=Value` is as valid as `Keyword Value`**, with optional
///   whitespace around the `=`.
/// - **Values can be quoted**, and a quoted value may contain spaces. Patterns
///   containing spaces are quoted for exactly that reason.
/// - **The first value wins**, not the last. Every other configuration format
///   in common use is the other way round, and getting it backwards silently
///   changes which user or port a host connects as.
/// - **`Host` takes several patterns**, and a leading `!` negates one.
public enum SSHConfigParser {
    public static func parse(_ text: String) -> SSHConfigFile {
        var file = SSHConfigFile()
        var current: SSHConfigFile.Block?

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let (keyword, value) = splitKeyword(line) else {
                file.unparsedLines.append(.init(keyword: "", value: line, lineNumber: lineNumber))
                continue
            }

            switch keyword.lowercased() {
            case "host":
                if let block = current { file.blocks.append(block) }
                current = SSHConfigFile.Block(
                    scope: .host(patterns: tokenise(value).map(SSHConfigPattern.init)),
                    lineNumber: lineNumber
                )

            case "match":
                if let block = current { file.blocks.append(block) }
                current = SSHConfigFile.Block(
                    scope: .match(criteria: parseMatch(value)),
                    lineNumber: lineNumber
                )

            case "include":
                // Kept unresolved: resolving means reading files and expanding
                // globs, and a parser that touches the file system cannot be
                // tested against a string.
                file.includes.append(.init(keyword: keyword, value: value, lineNumber: lineNumber))

            default:
                let setting = SSHConfigFile.Setting(keyword: keyword, value: value, lineNumber: lineNumber)
                if current != nil {
                    current?.settings.append(setting)
                } else {
                    // Before any Host or Match line. These apply to
                    // everything — and, because the first value wins, they
                    // beat every block below them.
                    if case .global? = file.blocks.first?.scope {
                        file.blocks[0].settings.append(setting)
                    } else {
                        file.blocks.insert(.init(scope: .global, settings: [setting], lineNumber: lineNumber), at: 0)
                    }
                }
            }
        }

        if let block = current { file.blocks.append(block) }
        return file
    }

    /// The settings that apply to `alias`, in the order OpenSSH would apply
    /// them — which is to say, first one wins.
    ///
    /// - Parameter localUser: the account sssh is running as, for
    ///   `Match localuser`. Absent means those blocks cannot be evaluated and
    ///   are skipped rather than guessed.
    public static func settings(
        for alias: String,
        in file: SSHConfigFile,
        localUser: String? = nil
    ) -> [SSHConfigFile.Setting] {
        var result: [SSHConfigFile.Setting] = []
        var seen = Set<String>()

        // `User` and `HostName` from earlier blocks change what a later
        // `Match` sees, which is why they are resolved as the file is walked
        // rather than up front.
        var state = MatchState(alias: alias, hostName: alias, user: nil, localUser: localUser)

        for block in file.blocks {
            guard applies(block, state: state) else { continue }
            for setting in block.settings {
                let key = setting.keyword.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(setting)
                if key == "user" { state.user = setting.value }
                if key == "hostname" { state.hostName = setting.value }
            }
        }
        return result
    }

    /// Convenience over ``settings(for:in:localUser:)``: the first value for a
    /// keyword, or nil.
    public static func value(
        of keyword: String,
        for alias: String,
        in file: SSHConfigFile,
        localUser: String? = nil
    ) -> String? {
        settings(for: alias, in: file, localUser: localUser)
            .first { $0.matches(keyword) }?
            .value
    }

    /// Every value for a keyword, for the ones that may legitimately repeat —
    /// `IdentityFile`, `LocalForward`, `SendEnv`.
    ///
    /// These are the exception to first-value-wins: OpenSSH accumulates them.
    public static func values(
        of keyword: String,
        for alias: String,
        in file: SSHConfigFile,
        localUser: String? = nil
    ) -> [String] {
        var result: [String] = []
        var state = MatchState(alias: alias, hostName: alias, user: nil, localUser: localUser)
        for block in file.blocks {
            guard applies(block, state: state) else { continue }
            for setting in block.settings {
                if setting.matches(keyword) { result.append(setting.value) }
                if setting.matches("User"), state.user == nil { state.user = setting.value }
                if setting.matches("HostName"), state.hostName == alias { state.hostName = setting.value }
            }
        }
        return result
    }

    // MARK: - Block matching

    /// What a `Match` line is evaluated against at a given point in the file.
    ///
    /// `hostName` starts as the alias and becomes whatever a `HostName` line
    /// sets it to, because that is what OpenSSH compares `Match host` against —
    /// the resolved name, not the alias. `Match originalhost` is the one that
    /// matches what the user typed. Getting these the same way round is not a
    /// detail: a file with `Host web` / `HostName web.example.com` /
    /// `Match host web` has a block that looks like it applies and does not.
    private struct MatchState {
        var alias: String
        var hostName: String
        var user: String?
        var localUser: String?
    }

    private static func applies(_ block: SSHConfigFile.Block, state: MatchState) -> Bool {
        switch block.scope {
        case .global:
            return true
        case .host(let patterns):
            // `Host` always matches the alias, whatever HostName says.
            return patterns.matchesHost(state.alias)
        case .match(let criteria):
            guard !criteria.isEmpty else { return false }
            return criteria.allSatisfy { criterion in
                switch criterion {
                case .all:
                    return true
                case .host(let patterns):
                    return patterns.matchesHost(state.hostName)
                case .originalHost(let patterns):
                    return patterns.matchesHost(state.alias)
                case .user(let patterns):
                    guard let user = state.user else { return false }
                    return patterns.matchesHost(user)
                case .localUser(let patterns):
                    guard let localUser = state.localUser else { return false }
                    return patterns.matchesHost(localUser)
                case .unevaluatable:
                    // Never true. `Match exec` would have to run a shell
                    // command to decide whether a block applies, and a config
                    // file that arrived by import or by sync is not something
                    // to execute. The import says which blocks it skipped.
                    return false
                }
            }
        }
    }

    // MARK: - Lexing

    /// Removes a trailing comment, respecting quotes.
    ///
    /// `#` inside a quoted value is part of the value — which matters, because
    /// a `ProxyCommand` or an `IdentityFile` path can contain one.
    static func stripComment(_ line: String) -> String {
        var result = ""
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes { break }
            result.append(character)
        }
        return result
    }

    /// Splits `Keyword Value` or `Keyword=Value`.
    static func splitKeyword(_ line: String) -> (keyword: String, value: String)? {
        var keyword = ""
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace || character == "=" { break }
            keyword.append(character)
            index = line.index(after: index)
        }
        guard !keyword.isEmpty else { return nil }

        // Whitespace, then at most one `=`, then whitespace again.
        var sawEquals = false
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace {
                index = line.index(after: index)
            } else if character == "=", !sawEquals {
                sawEquals = true
                index = line.index(after: index)
            } else {
                break
            }
        }

        let value = String(line[index...]).trimmingCharacters(in: .whitespaces)
        return (keyword, unquote(value))
    }

    /// Removes surrounding quotes from a whole value. Quotes around individual
    /// tokens are handled by ``tokenise(_:)``.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        // Only when the quotes are the outermost thing: `"a" "b"` is two
        // tokens, not one value with quotes in the middle.
        let inner = value.dropFirst().dropLast()
        guard !inner.contains("\"") else { return value }
        return String(inner)
    }

    /// Splits a value into whitespace-separated tokens, keeping quoted runs
    /// together.
    static func tokenise(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasContent = false

        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                // An empty quoted string is a token: `Host ""` is malformed,
                // but losing it silently is worse than keeping it.
                hasContent = true
                continue
            }
            if character.isWhitespace, !inQuotes {
                if hasContent { tokens.append(current) }
                current = ""
                hasContent = false
                continue
            }
            current.append(character)
            hasContent = true
        }
        if hasContent { tokens.append(current) }
        return tokens
    }

    /// `Match` criteria: `all`, or pairs of keyword and pattern list.
    static func parseMatch(_ value: String) -> [SSHConfigFile.MatchCriterion] {
        var criteria: [SSHConfigFile.MatchCriterion] = []
        var tokens = tokenise(value)[...]

        while let keyword = tokens.first {
            tokens = tokens.dropFirst()
            switch keyword.lowercased() {
            case "all":
                criteria.append(.all)
            case "canonical", "final":
                // Both are about OpenSSH's canonicalisation pass, which sssh
                // does not do. Treating them as never matching is the
                // conservative direction: it leaves settings out rather than
                // applying ones that should not be.
                criteria.append(.unevaluatable(keyword: keyword, value: ""))
            case "host", "originalhost", "user", "localuser", "exec", "tagged":
                guard let argument = tokens.first else {
                    criteria.append(.unevaluatable(keyword: keyword, value: ""))
                    break
                }
                tokens = tokens.dropFirst()
                let patterns = argument.split(separator: ",").map { SSHConfigPattern(String($0)) }
                switch keyword.lowercased() {
                case "host": criteria.append(.host(patterns))
                case "originalhost": criteria.append(.originalHost(patterns))
                case "user": criteria.append(.user(patterns))
                case "localuser": criteria.append(.localUser(patterns))
                default: criteria.append(.unevaluatable(keyword: keyword, value: argument))
                }
            default:
                criteria.append(.unevaluatable(keyword: keyword, value: ""))
            }
        }
        return criteria
    }
}
