import Foundation

/// A saved command with holes in it.
///
/// `{{name}}` is a parameter, and `{{name=default}}` gives it one. Everything
/// else is literal, including a lone `{` and a `{{` that is never closed —
/// shell scripts are full of braces, and a template language that eats
/// `${VAR}` or `awk '{print $1}'` is worse than none.
public struct SnippetTemplate: Hashable, Sendable {
    public struct Parameter: Hashable, Sendable, Identifiable {
        public var name: String
        public var defaultValue: String?
        public var id: String { name }

        public init(name: String, defaultValue: String? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    private enum Piece: Hashable, Sendable {
        case literal(String)
        case parameter(name: String)
    }

    public let text: String
    private let pieces: [Piece]

    public init(_ text: String) {
        self.text = text
        self.pieces = Self.split(text)
    }

    /// Every parameter, in the order it first appears — which is the order to
    /// ask for them in, because that is the order they read in the command.
    public var parameters: [Parameter] {
        let defaults = defaultsByName
        var seen = Set<String>()
        var result: [Parameter] = []

        for case .parameter(let raw) in pieces {
            let name = Self.splitDefault(raw).name
            guard seen.insert(name).inserted else { continue }
            result.append(Parameter(name: name, defaultValue: defaults[name]))
        }
        return result
    }

    /// One default per name, taken from wherever it was written.
    ///
    /// A parameter used twice — once as `{{a}}` and once as `{{a=d}}` — has
    /// one default, not one per occurrence. Resolving it per occurrence makes
    /// the same name expand to two different things in one command, which is
    /// never what was meant.
    private var defaultsByName: [String: String] {
        var defaults: [String: String] = [:]
        for case .parameter(let raw) in pieces {
            let (name, defaultValue) = Self.splitDefault(raw)
            if let defaultValue, defaults[name] == nil { defaults[name] = defaultValue }
        }
        return defaults
    }

    public var hasParameters: Bool { !parameters.isEmpty }

    /// Fills the holes. A parameter with no value and no default becomes an
    /// empty string rather than being left as `{{name}}`: sending the literal
    /// text to a shell is how a template becomes a syntax error at the far end.
    public func expanded(with values: [String: String]) -> String {
        let defaults = defaultsByName
        var result = ""
        for piece in pieces {
            switch piece {
            case .literal(let text):
                result += text
            case .parameter(let raw):
                let name = Self.splitDefault(raw).name
                result += values[name] ?? defaults[name] ?? ""
            }
        }
        return result
    }

    // MARK: - Parsing

    private static func split(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "{", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                  next < text.endIndex, text[next] == "{"
            else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }

            // `{{` with no closing `}}` is literal text. A shell script full
            // of braces must survive being saved as a snippet.
            let afterOpen = text.index(index, offsetBy: 2)
            guard let closing = text.range(of: "}}", range: afterOpen..<text.endIndex) else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }

            let name = String(text[afterOpen..<closing.lowerBound])
            // `{{}}` is not a parameter either; there is nothing to ask for.
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }

            if !literal.isEmpty {
                pieces.append(.literal(literal))
                literal = ""
            }
            pieces.append(.parameter(name: name))
            index = closing.upperBound
        }

        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    /// `name` or `name=default`. Everything after the first `=` is the
    /// default, so a default may itself contain one.
    ///
    /// Both sides are trimmed. Someone writing `{{ns = default}}` means the
    /// default to be `default`, not `" default"`, and a deliberately
    /// space-padded default is rare enough to be worth losing for that.
    private static func splitDefault(_ raw: String) -> (name: String, defaultValue: String?) {
        guard let equals = raw.firstIndex(of: "=") else {
            return (raw.trimmingCharacters(in: .whitespaces), nil)
        }
        let name = raw[raw.startIndex..<equals].trimmingCharacters(in: .whitespaces)
        let value = raw[raw.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }
}
