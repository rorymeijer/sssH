import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one place the platform clipboard is named.
///
/// Two lines of `#if os(macOS)` per call site adds up, and the difference is
/// not interesting enough to be repeated.
enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
