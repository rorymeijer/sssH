import XCTest
@testable import ssshCore

final class SnippetTemplateTests: XCTestCase {
    private func parameters(_ text: String) -> [(String, String?)] {
        SnippetTemplate(text).parameters.map { ($0.name, $0.defaultValue) }
    }

    private func assertParameters(_ text: String, _ expected: [(String, String?)], file: StaticString = #filePath, line: UInt = #line) {
        let actual = parameters(text)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    func testParametersAndSubstitution() {
        assertParameters("systemctl restart {{service}}", [("service", nil)])
        XCTAssertEqual(
            SnippetTemplate("systemctl restart {{service}}").expanded(with: ["service": "nginx"]),
            "systemctl restart nginx"
        )
    }

    func testDefaults() {
        assertParameters("tail -n {{lines=100}} {{path}}", [("lines", "100"), ("path", nil)])
        XCTAssertEqual(
            SnippetTemplate("tail -n {{lines=100}} {{path}}").expanded(with: ["path": "/var/log/syslog"]),
            "tail -n 100 /var/log/syslog"
        )
        XCTAssertEqual(
            SnippetTemplate("tail -n {{lines=100}} {{path}}").expanded(with: ["lines": "20", "path": "/x"]),
            "tail -n 20 /x"
        )
    }

    func testParametersAreListedOnceInOrderOfFirstUse() {
        assertParameters("{{b}} {{a}} {{b}}", [("b", nil), ("a", nil)])
        XCTAssertEqual(SnippetTemplate("echo {{a}} {{a}}").expanded(with: ["a": "x"]), "echo x x")
    }

    /// One default per name, not one per occurrence. Resolving it per
    /// occurrence makes the same name expand to two different things in one
    /// command.
    func testADefaultWrittenAnywhereAppliesEverywhere() {
        assertParameters("echo {{a}} {{a=d}}", [("a", "d")])
        XCTAssertEqual(SnippetTemplate("echo {{a}} {{a=d}}").expanded(with: [:]), "echo d d")
    }

    func testWhitespaceAroundTheEqualsIsTrimmed() {
        assertParameters("k get pods -n {{ns = default}}", [("ns", "default")])
        XCTAssertEqual(SnippetTemplate("k get pods -n {{ns = default}}").expanded(with: [:]), "k get pods -n default")
    }

    /// Everything after the first `=` is the default, so a path or a flag can
    /// contain one.
    func testDefaultMayContainAnEquals() {
        assertParameters("{{path=/var/log/a=b}}", [("path", "/var/log/a=b")])
        XCTAssertEqual(SnippetTemplate("{{path=/var/log/a=b}}").expanded(with: [:]), "/var/log/a=b")
    }

    /// The reason the syntax is `{{...}}` and not `{...}`: shell scripts are
    /// full of braces, and a template language that eats them is worse than
    /// none at all.
    func testShellBracesSurvive() {
        for command in [
            "awk '{print $1}'",
            "echo ${VAR}",
            "for i in {1..3}; do echo $i; done",
            "jq '.items[] | {name: .metadata.name}'",
        ] {
            let template = SnippetTemplate(command)
            XCTAssertTrue(template.parameters.isEmpty, command)
            XCTAssertEqual(template.expanded(with: [:]), command)
        }
    }

    func testUnclosedAndEmptyPlaceholdersAreLiteral() {
        XCTAssertEqual(SnippetTemplate("echo {{unclosed").expanded(with: [:]), "echo {{unclosed")
        XCTAssertTrue(SnippetTemplate("echo {{unclosed").parameters.isEmpty)
        XCTAssertEqual(SnippetTemplate("echo {{}}").expanded(with: [:]), "echo {{}}")
        XCTAssertTrue(SnippetTemplate("echo {{}}").parameters.isEmpty)
    }

    /// A parameter with nothing to fill it becomes empty rather than staying
    /// as `{{x}}`: sending the literal placeholder to a shell turns a template
    /// into a syntax error at the far end.
    func testMissingValueBecomesEmpty() {
        XCTAssertEqual(SnippetTemplate("missing {{x}}").expanded(with: [:]), "missing ")
    }

    func testAdjacentParameters() {
        XCTAssertEqual(SnippetTemplate("{{a}}{{b}}").expanded(with: ["a": "1", "b": "2"]), "12")
    }

    func testHasParameters() {
        XCTAssertTrue(SnippetTemplate("{{a}}").hasParameters)
        XCTAssertFalse(SnippetTemplate("uptime").hasParameters)
    }
}
