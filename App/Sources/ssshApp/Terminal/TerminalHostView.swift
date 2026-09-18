import SwiftTerm
import SwiftUI
import ssshCore

#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Hosts SwiftTerm inside SwiftUI.
///
/// The wiring is small and entirely conventional, which is the point: the
/// terminal is a `TerminalView`, input comes back through
/// `TerminalViewDelegate.send`, output goes in through `feed(byteArray:)`, and
/// a layout change becomes a `window-change`. Everything interesting happens on
/// either side of it.
struct TerminalHostView: PlatformViewRepresentable {
    let session: any TerminalFeed
    /// Typing is routed through the tab rather than straight to the session, so
    /// broadcast-to-all-panes is a property of the tab and not something every
    /// call site has to remember.
    let tab: TerminalTab
    let pane: PaneID
    let profile: TerminalProfile?

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, tab: tab, pane: pane)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> TerminalView { makeTerminalView(context: context) }
    func updateNSView(_ view: TerminalView, context: Context) { update(view, context: context) }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.detach() }
    #else
    func makeUIView(context: Context) -> TerminalView { makeTerminalView(context: context) }
    func updateUIView(_ view: TerminalView, context: Context) { update(view, context: context) }
    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) { coordinator.detach() }
    #endif

    private func makeTerminalView(context: Context) -> TerminalView {
        var options = TerminalOptions.default
        options.termName = TerminalType.xterm256Color.name
        options.scrollback = profile?.scrollbackLines ?? 10_000

        let view = TerminalView(frame: .zero, font: font, options: options)
        view.terminalDelegate = context.coordinator
        apply(scheme, to: view)

        context.coordinator.attach(to: view)
        return view
    }

    private func update(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = font
        }
        apply(scheme, to: view)
    }

    // MARK: - Appearance

    private var fontSize: CGFloat {
        CGFloat(profile?.fontSize ?? 13)
    }

    /// The system monospace face rather than a named font: it is present on
    /// every device, it respects the user's text-size settings, and a sandboxed
    /// app cannot address SF Mono by name anyway. Choosing a specific font is
    /// Phase 6.
    private var font: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private var scheme: TerminalColorScheme {
        TerminalColorScheme.bundled(named: profile?.colorSchemeName ?? TerminalColorScheme.systemDefault.name)
    }

    private func apply(_ scheme: TerminalColorScheme, to view: TerminalView) {
        view.installColors(scheme.swiftTermPalette)
        view.nativeBackgroundColor = platformColor(scheme.background)
        view.nativeForegroundColor = platformColor(scheme.foreground)
        view.caretColor = platformColor(scheme.cursor)
        view.selectedTextBackgroundColor = platformColor(scheme.selection)
    }

    private func platformColor(_ rgb: TerminalColorScheme.RGB) -> PlatformColor {
        PlatformColor(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }

    // MARK: - Coordinator

    /// The `TerminalViewDelegate`, and the only place that touches both
    /// SwiftTerm and the session.
    ///
    /// Not marked `@MainActor`, even though every one of these callbacks
    /// arrives on the main thread: `TerminalViewDelegate` declares its
    /// requirements without isolation, and an isolated method cannot witness a
    /// non-isolated one. `MainActor.assumeIsolated` states the fact rather than
    /// hopping — a hop would reorder input against output, which in a terminal
    /// means characters arriving out of order.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: any TerminalFeed
        private let tab: TerminalTab
        private let pane: PaneID
        private weak var view: TerminalView?

        init(session: any TerminalFeed, tab: TerminalTab, pane: PaneID) {
            self.session = session
            self.tab = tab
            self.pane = pane
        }

        func attach(to view: TerminalView) {
            MainActor.assumeIsolated {
                self.view = view
                // Output that arrived before the view existed is replayed here,
                // so a session that connected while its tab was off screen
                // still shows its banner and prompt.
                session.attachOutput { [weak view] bytes in
                    view?.feed(byteArray: bytes[...])
                }
            }
        }

        func detach() {
            MainActor.assumeIsolated {
                session.detachOutput()
                view = nil
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Everything typed, including Ctrl-C as byte 0x03. With a PTY
            // allocated it is the *remote* line discipline that turns that into
            // SIGINT — which is why this does not special-case it.
            MainActor.assumeIsolated {
                // Focus follows typing: a pane that receives a keystroke is the
                // one the user is in, whatever was last clicked.
                tab.focusedPane = pane
                tab.send(data, from: pane)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { session.updateRemoteTitle(title) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7. Phase 3 uses it to label command blocks; ignored for now.
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // Only open what a terminal link plausibly is. A remote host can
            // print any escape sequence it likes, so handing an arbitrary
            // scheme to the system opener would let it launch things.
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else {
                return
            }

            MainActor.assumeIsolated {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
        }

        func bell(source: TerminalView) {
            #if os(macOS)
            MainActor.assumeIsolated { NSSound.beep() }
            #endif
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #else
                UIPasteboard.general.string = text
                #endif
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            // OSC 52 read. Denied: it lets a remote host exfiltrate whatever the
            // user last copied, which could be a password out of a manager.
            // Granting it needs a prompt, which is Phase 8.
            nil
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
