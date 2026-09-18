import XCTest
@testable import ssshCore

/// Every expectation here was checked against OpenSSH 9.6's own `ssh -G`,
/// which is the only authority on what this format means. Where sssh
/// deliberately differs — it will not run a `Match exec` — the test says so.
final class SSHConfigParserTests: XCTestCase {
    private let sample = """
    # a global setting, before any Host line
    ServerAliveInterval 15

    Host prod
        HostName prod.example.com
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_prod
        IdentityFile ~/.ssh/id_backup

    Host staging stage
        HostName staging.example.com
        User=deploy
        ProxyJump bastion

    Host bastion
        HostName bastion.example.com
        User jump

    Host *.internal !secret.internal
        User internal-user
        Port 2200

    Host prod
        # first value wins, so this User is ignored
        User ignored-because-later
        Compression yes

    Host *
        User fallback
        ServerAliveInterval 300
        ForwardAgent no
    """

    private func value(_ keyword: String, _ alias: String) -> String? {
        SSHConfigParser.value(of: keyword, for: alias, in: SSHConfigParser.parse(sample))
    }

    /// The rule that catches everyone: OpenSSH takes the *first* value it
    /// sees, not the last. Getting it backwards silently changes which user a
    /// host connects as.
    func testFirstValueWins() {
        XCTAssertEqual(value("User", "prod"), "deploy")
        XCTAssertEqual(value("Port", "prod"), "2222")
        // A later block still contributes keywords nobody has set yet.
        XCTAssertEqual(value("Compression", "prod"), "yes")
    }

    /// Settings before any `Host` line apply to everything — and, because the
    /// first value wins, they beat the `Host *` block at the bottom.
    func testGlobalSettingsBeatTheCatchAllBlock() {
        XCTAssertEqual(value("ServerAliveInterval", "prod"), "15")
        XCTAssertEqual(value("ServerAliveInterval", "anything-at-all"), "15")
    }

    func testSeveralPatternsOnOneHostLine() {
        XCTAssertEqual(value("HostName", "staging"), "staging.example.com")
        XCTAssertEqual(value("HostName", "stage"), "staging.example.com")
        XCTAssertEqual(value("ProxyJump", "stage"), "bastion")
    }

    func testWildcardsAndNegation() {
        XCTAssertEqual(value("User", "foo.internal"), "internal-user")
        XCTAssertEqual(value("Port", "foo.internal"), "2200")
        // Negated, so it falls through to `Host *`.
        XCTAssertEqual(value("User", "secret.internal"), "fallback")
        XCTAssertEqual(value("Port", "secret.internal"), nil)
        XCTAssertEqual(value("User", "other"), "fallback")
    }

    /// `IdentityFile` is one of the few keywords that accumulates instead of
    /// being first-value-wins.
    func testIdentityFilesAccumulateInOrder() {
        let files = SSHConfigParser.values(of: "IdentityFile", for: "prod", in: SSHConfigParser.parse(sample))
        XCTAssertEqual(files, ["~/.ssh/id_prod", "~/.ssh/id_backup"])
    }

    func testImportableAliasesSkipWildcards() {
        let aliases = SSHConfigParser.parse(sample).importableAliases
        // `*.internal`, `!secret.internal` and `*` name families, not hosts.
        XCTAssertEqual(aliases, ["prod", "staging", "stage", "bastion"])
    }

    // MARK: - Lexing

    func testEqualsSeparatorWithAndWithoutSpaces() {
        let file = SSHConfigParser.parse("""
        Host eq
            HostName=eq.example.com
            Port   =   2022
            User = eq-user
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "HostName", for: "eq", in: file), "eq.example.com")
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "eq", in: file), "2022")
        XCTAssertEqual(SSHConfigParser.value(of: "User", for: "eq", in: file), "eq-user")
    }

    func testCommentsAreStrippedButNotInsideQuotes() {
        let file = SSHConfigParser.parse("""
        Host tail
            HostName tail.example.com # not part of the value
            IdentityFile "~/.ssh/key#1"
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "HostName", for: "tail", in: file), "tail.example.com")
        // A `#` inside quotes is part of the path, and paths do contain them.
        XCTAssertEqual(SSHConfigParser.values(of: "IdentityFile", for: "tail", in: file), ["~/.ssh/key#1"])
    }

    func testQuotedPatternsStayTogether() {
        let file = SSHConfigParser.parse("""
        Host "quoted host" plainhost
            HostName quoted.example.com
        """)
        guard case .host(let patterns)? = file.blocks.first?.scope else {
            return XCTFail("expected a host block")
        }
        XCTAssertEqual(patterns.map(\.text), ["quoted host", "plainhost"])
    }

    func testKeywordsAreCaseInsensitive() {
        let file = SSHConfigParser.parse("""
        HOST casing
            hostname CASE.example.com
            PORT 2020
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "HostName", for: "casing", in: file), "CASE.example.com")
        XCTAssertEqual(SSHConfigParser.value(of: "port", for: "casing", in: file), "2020")
    }

    // MARK: - Match

    /// `Match host` compares against the *resolved* `HostName`, not the alias.
    /// `Match originalhost` is the one that matches what the user typed. A
    /// file with `Host web` / `HostName web.example.com` / `Match host web`
    /// has a block that looks like it applies and does not.
    func testMatchHostComparesTheResolvedHostName() {
        let file = SSHConfigParser.parse("""
        Host m
            HostName m.example.com

        Match host m.example.com
            Port 9999
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "m", in: file), "9999")

        let aliasMatch = SSHConfigParser.parse("""
        Host m
            HostName m.example.com

        Match host m
            Port 9999
        """)
        XCTAssertNil(SSHConfigParser.value(of: "Port", for: "m", in: aliasMatch))
    }

    func testMatchOriginalHostComparesTheAlias() {
        let file = SSHConfigParser.parse("""
        Host m
            HostName m.example.com

        Match originalhost m
            Port 8888
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "m", in: file), "8888")
    }

    func testMatchUserSeesTheUserSetEarlier() {
        let file = SSHConfigParser.parse("""
        Host m
            HostName m.example.com
            User alice

        Match host m.example.com user alice
            Port 7777
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "m", in: file), "7777")

        let wrongUser = SSHConfigParser.parse("""
        Host m
            HostName m.example.com
            User alice

        Match host m.example.com user bob
            Port 7777
        """)
        XCTAssertNil(SSHConfigParser.value(of: "Port", for: "m", in: wrongUser))
    }

    func testMatchLocalUser() {
        let file = SSHConfigParser.parse("""
        Match localuser rory
            Port 4242
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "anything", in: file, localUser: "rory"), "4242")
        XCTAssertNil(SSHConfigParser.value(of: "Port", for: "anything", in: file, localUser: "someone-else"))
        // With no local user to compare against, the block is skipped rather
        // than guessed at.
        XCTAssertNil(SSHConfigParser.value(of: "Port", for: "anything", in: file))
    }

    /// The one deliberate divergence from `ssh`. `Match exec` asks the config
    /// file to run a shell command in order to decide whether a block applies,
    /// and a file that arrives by import or by sync is not something to
    /// execute. `ssh -G` applies this block; sssh does not, and says so.
    func testMatchExecIsNeverEvaluated() {
        let file = SSHConfigParser.parse("""
        Match exec "true"
            Port 7777
        """)
        XCTAssertNil(SSHConfigParser.value(of: "Port", for: "anything", in: file))

        let warnings = SSHConfigImporter.makeImport(from: file).warnings
        XCTAssertTrue(warnings.contains { if case .matchNotEvaluated(let keyword, _) = $0 { return keyword == "exec" } else { return false } })
    }

    func testMatchAll() {
        let file = SSHConfigParser.parse("""
        Match all
            Port 2121
        """)
        XCTAssertEqual(SSHConfigParser.value(of: "Port", for: "anything", in: file), "2121")
    }

    // MARK: - Patterns

    func testPatternMatching() {
        XCTAssertTrue(SSHConfigPattern.matches("web1.example.com", pattern: "*.example.com"))
        XCTAssertTrue(SSHConfigPattern.matches("web1", pattern: "web?"))
        XCTAssertFalse(SSHConfigPattern.matches("web10", pattern: "web?"))
        XCTAssertTrue(SSHConfigPattern.matches("anything", pattern: "*"))
        XCTAssertTrue(SSHConfigPattern.matches("", pattern: "*"))
        XCTAssertFalse(SSHConfigPattern.matches("", pattern: "?"))
        // `*` crosses dots: these are not shell globs.
        XCTAssertTrue(SSHConfigPattern.matches("a.b.c", pattern: "a*c"))
        XCTAssertTrue(SSHConfigPattern.matches("aaa", pattern: "a*a*a"))
        XCTAssertFalse(SSHConfigPattern.matches("aab", pattern: "a*a*a"))
    }

    /// A recursive matcher takes exponential time on this. The iterative one
    /// does not, and a config file can arrive by sync.
    func testPathologicalPatternDoesNotHang() {
        let candidate = String(repeating: "a", count: 64)
        XCTAssertFalse(SSHConfigPattern.matches(candidate, pattern: "a*a*a*a*a*a*a*a*b"))
    }

    func testNegationOnlyMatchesNothing() {
        let patterns = [SSHConfigPattern("!a")]
        XCTAssertFalse(patterns.matchesHost("a"))
        XCTAssertFalse(patterns.matchesHost("b"))
    }
}
