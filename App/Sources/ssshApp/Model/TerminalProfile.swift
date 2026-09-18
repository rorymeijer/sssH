import Foundation
import SwiftData

/// Font, colours and cursor for a terminal, assignable per host or group.
///
/// The scheme library is a fixed list of bundled palettes rather than an
/// entity: a scheme is sixteen colours that only mean anything together, and
/// letting each one be edited independently is how a designed set becomes an
/// unreadable one.
@Model
final class TerminalProfile {
    var name: String = ""
    var fontName: String = TerminalProfile.defaultFontName
    var fontSize: Double = 13
    /// Name of a bundled colour scheme. Custom schemes get their own entity in
    /// Phase 6 rather than being stuffed in here.
    var colorSchemeName: String = TerminalColorScheme.systemDefault.name
    var cursorStyleRaw: String = TerminalCursorStyle.blinkingBlock.rawValue
    var useLigatures: Bool = false
    var scrollbackLines: Int = 10_000
    var isBuiltIn: Bool = false

    /// The hosts assigned this profile. Never read directly — it exists
    /// because CloudKit sync refuses any relationship without an inverse.
    /// Nullify: deleting a profile drops those hosts back to the default.
    @Relationship(deleteRule: .nullify, inverse: \Host.terminalProfile)
    var hosts: [Host]? = []

    init(name: String = "") {
        self.name = name
    }

    /// SF Mono is present on every Mac and iOS device but is not addressable by
    /// that name from a sandboxed app, so this resolves to the system monospace
    /// face at render time.
    static let defaultFontName = "SFMono-Regular"

    var cursorStyle: TerminalCursorStyle {
        get { TerminalCursorStyle(rawValue: cursorStyleRaw) ?? .blinkingBlock }
        set { cursorStyleRaw = newValue.rawValue }
    }
}

enum TerminalCursorStyle: String, CaseIterable, Sendable {
    case blinkingBlock
    case steadyBlock
    case blinkingUnderline
    case steadyUnderline
    case blinkingBar
    case steadyBar
}
