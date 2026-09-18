import SwiftUI
import SwiftData

/// Terminal profiles: font, colours, cursor, scrollback.
struct TerminalProfileListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TerminalProfile.name) private var profiles: [TerminalProfile]
    @State private var editing: TerminalProfile?

    var body: some View {
        NavigationStack {
            List {
                ForEach(profiles) { profile in
                    Button {
                        editing = profile
                    } label: {
                        HStack(spacing: 10) {
                            SchemeSwatch(scheme: TerminalColorScheme.bundled(named: profile.colorSchemeName))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: profile.name.isEmpty ? profile.colorSchemeName : profile.name)
                                Text(verbatim: "\(profile.colorSchemeName) · \(Int(profile.fontSize)) pt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets where !profiles[index].isBuiltIn {
                        modelContext.delete(profiles[index])
                    }
                }
            }
            .overlay {
                if profiles.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Geen profielen", comment: "Empty state title for the terminal profile list")
                        } icon: {
                            Image(systemName: "paintpalette")
                        }
                    } description: {
                        Text("Een profiel bepaalt lettertype, kleuren en cursor. Je kunt er een per host of per groep instellen.",
                             comment: "Empty state body for the terminal profile list")
                    }
                }
            }
            .navigationTitle(Text("Terminalprofielen", comment: "Title of the terminal profile list"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    Button {
                        let profile = TerminalProfile(name: "")
                        modelContext.insert(profile)
                        editing = profile
                    } label: {
                        Label {
                            Text("Profiel toevoegen", comment: "Button that adds a terminal profile")
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
        }
        .sheet(item: $editing) { profile in
            TerminalProfileEditor(profile: profile)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

struct TerminalProfileEditor: View {
    @Bindable var profile: TerminalProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $profile.name) {
                        Text("Naam", comment: "Placeholder for a new folder's name")
                    }
                }

                Section {
                    ForEach(TerminalColorScheme.bundled) { scheme in
                        Button {
                            profile.colorSchemeName = scheme.name
                        } label: {
                            HStack(spacing: 10) {
                                SchemeSwatch(scheme: scheme)
                                Text(verbatim: scheme.name)
                                Spacer(minLength: 0)
                                if profile.colorSchemeName == scheme.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(profile.colorSchemeName == scheme.name ? [.isSelected, .isButton] : .isButton)
                    }
                } header: {
                    Text("Kleuren", comment: "Section header for the colour scheme picker")
                }

                Section {
                    LabeledContent {
                        Slider(value: $profile.fontSize, in: 8...32, step: 1)
                    } label: {
                        Text("Tekengrootte: \(Int(profile.fontSize))", comment: "Label for the font size slider, with the current value")
                    }

                    Toggle(isOn: $profile.useLigatures) {
                        Text("Ligaturen", comment: "Toggle for programming ligatures")
                    }

                    Picker(selection: Binding(get: { profile.cursorStyle }, set: { profile.cursorStyle = $0 })) {
                        Text("Blok", comment: "Cursor style: block").tag(TerminalCursorStyle.blinkingBlock)
                        Text("Blok, stil", comment: "Cursor style: steady block").tag(TerminalCursorStyle.steadyBlock)
                        Text("Streep", comment: "Cursor style: underline").tag(TerminalCursorStyle.blinkingUnderline)
                        Text("Streep, stil", comment: "Cursor style: steady underline").tag(TerminalCursorStyle.steadyUnderline)
                        Text("Balk", comment: "Cursor style: bar").tag(TerminalCursorStyle.blinkingBar)
                        Text("Balk, stil", comment: "Cursor style: steady bar").tag(TerminalCursorStyle.steadyBar)
                    } label: {
                        Text("Cursor", comment: "Label for the cursor style picker")
                    }
                } header: {
                    Text("Tekst", comment: "Section header for font settings")
                }

                Section {
                    LabeledContent {
                        Stepper(value: $profile.scrollbackLines, in: 1_000...200_000, step: 1_000) {
                            Text(verbatim: "\(profile.scrollbackLines)")
                        }
                    } label: {
                        Text("Terugbladeren", comment: "Label for the scrollback setting")
                    }
                } footer: {
                    Text("Meer regels kosten geheugen, per venster. Bij veel gesplitste vensters telt dat op.",
                         comment: "Explains the cost of a large scrollback")
                }

                Section {
                    SchemePreview(scheme: TerminalColorScheme.bundled(named: profile.colorSchemeName), fontSize: profile.fontSize)
                } header: {
                    Text("Voorbeeld", comment: "Section header for the colour scheme preview")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Profiel", comment: "Title of the terminal profile editor"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

/// Four colours in a row, enough to tell two schemes apart at a glance.
private struct SchemeSwatch: View {
    let scheme: TerminalColorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array([scheme.background, scheme.foreground, scheme.ansi[1], scheme.ansi[4]].enumerated()), id: \.offset) { _, colour in
                Rectangle().fill(colour.swiftUIColor)
            }
        }
        .frame(width: 44, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }
}

/// A line of fake terminal output.
///
/// Rendered from the scheme's own colours rather than a screenshot, so it is
/// right for a custom scheme too, and so the text scales with the font size
/// being chosen.
private struct SchemePreview: View {
    let scheme: TerminalColorScheme
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(verbatim: "user@host")
                    .foregroundStyle(scheme.ansi[2].swiftUIColor)
                Text(verbatim: ":~$ ")
                    .foregroundStyle(scheme.foreground.swiftUIColor)
                Text(verbatim: "ls -l")
                    .foregroundStyle(scheme.ansi[4].swiftUIColor)
            }
            Text(verbatim: "drwxr-xr-x  2 user  staff   64 projects")
                .foregroundStyle(scheme.ansi[6].swiftUIColor)
            Text(verbatim: "-rw-r--r--  1 user  staff  512 notes.txt")
                .foregroundStyle(scheme.foreground.swiftUIColor)
            Text(verbatim: "error: connection refused")
                .foregroundStyle(scheme.ansi[1].swiftUIColor)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(scheme.background.swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Voorbeeld van het kleurenschema", comment: "Accessibility label for the colour scheme preview"))
    }
}
