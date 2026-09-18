import Foundation
import SwiftTerm
import SwiftUI

/// A terminal colour scheme: the 16 ANSI colours plus the four the chrome uses.
///
/// Components are 8-bit here because that is how every published scheme is
/// written; SwiftTerm wants 16-bit, and the conversion multiplies by 257 rather
/// than shifting by 8 so that 0xFF maps to 0xFFFF exactly.
struct TerminalColorScheme: Identifiable, Hashable, Sendable {
    struct RGB: Hashable, Sendable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 0xRRGGBB, the form schemes are published in.
        init(hex: UInt32) {
            self.red = UInt8(truncatingIfNeeded: hex >> 16)
            self.green = UInt8(truncatingIfNeeded: hex >> 8)
            self.blue = UInt8(truncatingIfNeeded: hex)
        }

        var swiftTermColor: SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16(red) * 257,
                green: UInt16(green) * 257,
                blue: UInt16(blue) * 257
            )
        }

        var swiftUIColor: SwiftUI.Color {
            SwiftUI.Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255
            )
        }
    }

    var name: String
    /// Black, red, green, yellow, blue, magenta, cyan, white, then the eight
    /// bright variants — the order SwiftTerm's `installColors` expects.
    var ansi: [RGB]
    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var selection: RGB
    /// Drives the terminal's own appearance so a light scheme does not get a
    /// dark scrollbar.
    var isDark: Bool

    var id: String { name }

    /// Localised through the String Catalog by the UI; the stored `name` is a
    /// stable identifier, not display text.
    static let systemDefault = TerminalColorScheme(
        name: "sssh Dark",
        ansi: [
            RGB(hex: 0x1C1C1E), RGB(hex: 0xFF6B6B), RGB(hex: 0x5AD67D), RGB(hex: 0xE6C07B),
            RGB(hex: 0x61AFEF), RGB(hex: 0xC678DD), RGB(hex: 0x56B6C2), RGB(hex: 0xD5D5D7),
            RGB(hex: 0x5A5A5E), RGB(hex: 0xFF8787), RGB(hex: 0x7EE2A0), RGB(hex: 0xF0D399),
            RGB(hex: 0x82C0FF), RGB(hex: 0xD99BE8), RGB(hex: 0x74CDD8), RGB(hex: 0xFFFFFF),
        ],
        background: RGB(hex: 0x1C1C1E),
        foreground: RGB(hex: 0xD5D5D7),
        cursor: RGB(hex: 0x61AFEF),
        selection: RGB(hex: 0x3A3A3C),
        isDark: true
    )

    static let light = TerminalColorScheme(
        name: "sssh Light",
        ansi: [
            RGB(hex: 0x2B2B2B), RGB(hex: 0xC5232B), RGB(hex: 0x1C8C3C), RGB(hex: 0x9A6A00),
            RGB(hex: 0x1A6FD4), RGB(hex: 0x9B3FBF), RGB(hex: 0x117A8B), RGB(hex: 0xE8E8E8),
            RGB(hex: 0x6B6B6B), RGB(hex: 0xE04A52), RGB(hex: 0x2FAA5A), RGB(hex: 0xC08A16),
            RGB(hex: 0x4090EE), RGB(hex: 0xB765D6), RGB(hex: 0x2AA0AF), RGB(hex: 0xFFFFFF),
        ],
        background: RGB(hex: 0xFCFCFC),
        foreground: RGB(hex: 0x2B2B2B),
        cursor: RGB(hex: 0x1A6FD4),
        selection: RGB(hex: 0xD6E4FA),
        isDark: false
    )

    /// Solarized, by Ethan Schoonover. The published palette: its point is
    /// that the sixteen slots are a designed relationship rather than sixteen
    /// independent choices, so nothing here is adjusted to taste.
    static let solarizedDark = TerminalColorScheme(
        name: "Solarized Dark",
        ansi: [
            RGB(hex: 0x073642), RGB(hex: 0xDC322F), RGB(hex: 0x859900), RGB(hex: 0xB58900),
            RGB(hex: 0x268BD2), RGB(hex: 0xD33682), RGB(hex: 0x2AA198), RGB(hex: 0xEEE8D5),
            RGB(hex: 0x002B36), RGB(hex: 0xCB4B16), RGB(hex: 0x586E75), RGB(hex: 0x657B83),
            RGB(hex: 0x839496), RGB(hex: 0x6C71C4), RGB(hex: 0x93A1A1), RGB(hex: 0xFDF6E3),
        ],
        background: RGB(hex: 0x002B36),
        foreground: RGB(hex: 0x839496),
        cursor: RGB(hex: 0x93A1A1),
        selection: RGB(hex: 0x073642),
        isDark: true
    )

    static let solarizedLight = TerminalColorScheme(
        name: "Solarized Light",
        ansi: [
            RGB(hex: 0x073642), RGB(hex: 0xDC322F), RGB(hex: 0x859900), RGB(hex: 0xB58900),
            RGB(hex: 0x268BD2), RGB(hex: 0xD33682), RGB(hex: 0x2AA198), RGB(hex: 0xEEE8D5),
            RGB(hex: 0x002B36), RGB(hex: 0xCB4B16), RGB(hex: 0x586E75), RGB(hex: 0x657B83),
            RGB(hex: 0x839496), RGB(hex: 0x6C71C4), RGB(hex: 0x93A1A1), RGB(hex: 0xFDF6E3),
        ],
        background: RGB(hex: 0xFDF6E3),
        foreground: RGB(hex: 0x657B83),
        cursor: RGB(hex: 0x586E75),
        selection: RGB(hex: 0xEEE8D5),
        isDark: false
    )

    /// Nord, by Arctic Ice Studio.
    static let nord = TerminalColorScheme(
        name: "Nord",
        ansi: [
            RGB(hex: 0x3B4252), RGB(hex: 0xBF616A), RGB(hex: 0xA3BE8C), RGB(hex: 0xEBCB8B),
            RGB(hex: 0x81A1C1), RGB(hex: 0xB48EAD), RGB(hex: 0x88C0D0), RGB(hex: 0xE5E9F0),
            RGB(hex: 0x4C566A), RGB(hex: 0xBF616A), RGB(hex: 0xA3BE8C), RGB(hex: 0xEBCB8B),
            RGB(hex: 0x81A1C1), RGB(hex: 0xB48EAD), RGB(hex: 0x8FBCBB), RGB(hex: 0xECEFF4),
        ],
        background: RGB(hex: 0x2E3440),
        foreground: RGB(hex: 0xD8DEE9),
        cursor: RGB(hex: 0xD8DEE9),
        selection: RGB(hex: 0x434C5E),
        isDark: true
    )

    /// Gruvbox Dark, by Pavel Pertsev.
    static let gruvboxDark = TerminalColorScheme(
        name: "Gruvbox Dark",
        ansi: [
            RGB(hex: 0x282828), RGB(hex: 0xCC241D), RGB(hex: 0x98971A), RGB(hex: 0xD79921),
            RGB(hex: 0x458588), RGB(hex: 0xB16286), RGB(hex: 0x689D6A), RGB(hex: 0xA89984),
            RGB(hex: 0x928374), RGB(hex: 0xFB4934), RGB(hex: 0xB8BB26), RGB(hex: 0xFABD2F),
            RGB(hex: 0x83A598), RGB(hex: 0xD3869B), RGB(hex: 0x8EC07C), RGB(hex: 0xEBDBB2),
        ],
        background: RGB(hex: 0x282828),
        foreground: RGB(hex: 0xEBDBB2),
        cursor: RGB(hex: 0xEBDBB2),
        selection: RGB(hex: 0x504945),
        isDark: true
    )

    /// Dracula, by Zeno Rocha.
    static let dracula = TerminalColorScheme(
        name: "Dracula",
        ansi: [
            RGB(hex: 0x21222C), RGB(hex: 0xFF5555), RGB(hex: 0x50FA7B), RGB(hex: 0xF1FA8C),
            RGB(hex: 0xBD93F9), RGB(hex: 0xFF79C6), RGB(hex: 0x8BE9FD), RGB(hex: 0xF8F8F2),
            RGB(hex: 0x6272A4), RGB(hex: 0xFF6E6E), RGB(hex: 0x69FF94), RGB(hex: 0xFFFFA5),
            RGB(hex: 0xD6ACFF), RGB(hex: 0xFF92DF), RGB(hex: 0xA4FFFF), RGB(hex: 0xFFFFFF),
        ],
        background: RGB(hex: 0x282A36),
        foreground: RGB(hex: 0xF8F8F2),
        cursor: RGB(hex: 0xF8F8F2),
        selection: RGB(hex: 0x44475A),
        isDark: true
    )

    /// A high-contrast scheme, for bright rooms and for people who find the
    /// fashionable low-contrast palettes unreadable. Not an afterthought: the
    /// default schemes are all in the 4.5:1 region, and some people need much
    /// more than that.
    static let highContrast = TerminalColorScheme(
        name: "Hoog contrast",
        ansi: [
            RGB(hex: 0x000000), RGB(hex: 0xFF5F5F), RGB(hex: 0x5FFF5F), RGB(hex: 0xFFFF5F),
            RGB(hex: 0x5F9FFF), RGB(hex: 0xFF5FFF), RGB(hex: 0x5FFFFF), RGB(hex: 0xFFFFFF),
            RGB(hex: 0x7F7F7F), RGB(hex: 0xFF8787), RGB(hex: 0x87FF87), RGB(hex: 0xFFFF87),
            RGB(hex: 0x87BFFF), RGB(hex: 0xFF87FF), RGB(hex: 0x87FFFF), RGB(hex: 0xFFFFFF),
        ],
        background: RGB(hex: 0x000000),
        foreground: RGB(hex: 0xFFFFFF),
        cursor: RGB(hex: 0xFFFF00),
        selection: RGB(hex: 0x00519E),
        isDark: true
    )

    /// Every scheme that ships.
    ///
    /// The third-party palettes are the published ones, unadjusted. Their
    /// point is that the sixteen slots are a designed relationship, and
    /// "improving" one colour breaks the set.
    static let bundled: [TerminalColorScheme] = [
        .systemDefault, .light, .solarizedDark, .solarizedLight,
        .nord, .gruvboxDark, .dracula, .highContrast,
    ]

    static func bundled(named name: String) -> TerminalColorScheme {
        bundled.first { $0.name == name } ?? .systemDefault
    }

    /// The 16 ANSI colours in SwiftTerm's form. Padded if a scheme is short, so
    /// a malformed custom scheme degrades instead of being silently ignored —
    /// `installColors` does nothing at all unless it gets exactly 16.
    var swiftTermPalette: [SwiftTerm.Color] {
        var palette = ansi.prefix(16).map(\.swiftTermColor)
        while palette.count < 16 {
            palette.append(foreground.swiftTermColor)
        }
        return palette
    }
}
