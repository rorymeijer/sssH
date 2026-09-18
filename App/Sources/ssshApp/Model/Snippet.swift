import Foundation
import SwiftData
import ssshCore

/// A saved command.
///
/// Defaults on everything and no unique constraints, for CloudKit, as with
/// every other model here. A snippet is text the user wrote; it carries no
/// secret, so it syncs freely.
///
/// Notably it is not run on its own initiative and never has a "run on
/// connect" flag. A snippet is typed into a session by the person looking at
/// it, and a saved command that fires by itself on an unfamiliar machine is a
/// way to lose an afternoon.
@Model
final class Snippet {
    var name: String = ""
    var command: String = ""
    var snippetDescription: String = ""
    var tags: [String] = []
    /// Send a newline after the command, running it. Off means "type it and
    /// leave the cursor there", which is what you want for anything
    /// destructive or half-remembered.
    var runsImmediately: Bool = true
    /// When set, the snippet is offered only on this host.
    var host: Host?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastUsedAt: Date?
    var useCount: Int = 0

    init(name: String = "", command: String = "") {
        self.name = name
        self.command = command
    }
}

extension Snippet {
    var template: SnippetTemplate { SnippetTemplate(command) }

    var parameters: [SnippetTemplate.Parameter] { template.parameters }

    /// The bytes to send for a filled-in snippet.
    ///
    /// A carriage return, not a line feed: a PTY in canonical mode expects
    /// `\r` from a terminal, and `\n` leaves the line unsubmitted in some
    /// shells and doubles it in others.
    func input(with values: [String: String]) -> [UInt8] {
        var bytes = Array(template.expanded(with: values).utf8)
        if runsImmediately { bytes.append(0x0D) }
        return bytes
    }

    func recordUse() {
        lastUsedAt = Date()
        useCount += 1
    }

    /// Searchable text for the palette.
    var keywords: [String] {
        tags + [command]
    }
}
