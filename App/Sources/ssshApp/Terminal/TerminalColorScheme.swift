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

    /// Every scheme that ships in Phase 1. The library and the custom-scheme
    /// editor are Phase 6.
    static let bundled: [TerminalColorScheme] = [.systemDefault, .light]

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
