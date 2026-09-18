import SwiftUI
import SwiftData
import ssshCore

/// The snippet library: everything global, plus whatever is saved against the
/// host in front of you.
struct SnippetLibraryView: View {
    /// Where a chosen snippet goes. Nil in the settings window, where the
    /// library is only being edited.
    let feed: (any TerminalFeed)?
    let host: Host?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Snippet.name) private var allSnippets: [Snippet]

    @State private var search = ""
    @State private var editing: Snippet?
    @State private var filling: Snippet?

    private var snippets: [Snippet] {
        let hostID = host?.persistentModelID
        return allSnippets.filter { snippet in
            // A snippet saved against another host is not offered here: it is
            // almost always specific to that machine, and running it on the
            // wrong one is the mistake the scoping exists to prevent.
            guard snippet.host == nil || snippet.host?.persistentModelID == hostID else { return false }
            let query = search.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return true }
            let options: String.CompareOptions = query.contains(where: \.isUppercase)
                ? [.literal] : [.caseInsensitive, .literal]
            return snippet.name.range(of: query, options: options) != nil
                || snippet.command.range(of: query, options: options) != nil
                || snippet.tags.contains { $0.range(of: query, options: options) != nil }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(snippets) { snippet in
                    SnippetRow(snippet: snippet, canRun: feed != nil) {
                        use(snippet)
                    } edit: {
                        editing = snippet
                    }
                }
                .onDelete { offsets in
                    for index in offsets { modelContext.delete(snippets[index]) }
                }
            }
            .searchable(text: $search, prompt: Text("Zoek fragmenten", comment: "Search field placeholder in the snippet library"))
            .overlay {
                if snippets.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Geen fragmenten", comment: "Empty state title for the snippet library")
                        } icon: {
                            Image(systemName: "text.badge.plus")
                        }
                    } description: {
                        Text("Bewaar opdrachten die je vaker gebruikt. Met {{naam}} vraagt sssH om een waarde voordat het wordt verstuurd.",
                             comment: "Empty state body for the snippet library, explaining the placeholder syntax")
                    }
                }
            }
            .navigationTitle(Text("Fragmenten", comment: "Title of the snippet library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    Button {
                        let snippet = Snippet(name: "", command: "")
                        snippet.host = host
                        modelContext.insert(snippet)
                        editing = snippet
                    } label: {
                        Label {
                            Text("Fragment toevoegen", comment: "Button that adds a snippet")
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
        .sheet(item: $editing) { snippet in
            SnippetEditorView(snippet: snippet, host: host)
        }
        .sheet(item: $filling) { snippet in
            SnippetParameterPrompt(snippet: snippet) { values in
                send(snippet, values: values)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private func use(_ snippet: Snippet) {
        guard feed != nil else { return }
        if snippet.parameters.isEmpty {
            send(snippet, values: [:])
        } else {
            filling = snippet
        }
    }

    private func send(_ snippet: Snippet, values: [String: String]) {
        guard let feed else { return }
        feed.send(ArraySlice(snippet.input(with: values)))
        snippet.recordUse()
        dismiss()
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let canRun: Bool
    let run: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: snippet.name.isEmpty ? snippet.command : snippet.name)
                    .lineLimit(1)
                Text(verbatim: snippet.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !snippet.parameters.isEmpty {
                    Text("\(snippet.parameters.count) invulveld(en)",
                         comment: "How many placeholders a snippet has")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if snippet.host != nil {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Alleen op deze host", comment: "Marks a snippet as host-specific"))
            }

            Button(action: edit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Bewerken", comment: "Button: edit"))

            Button(action: run) {
                Image(systemName: snippet.runsImmediately ? "play.fill" : "text.cursor")
            }
            .buttonStyle(.borderless)
            .disabled(!canRun)
            .accessibilityLabel(
                snippet.runsImmediately
                    ? Text("Uitvoeren", comment: "Button that sends a snippet and runs it")
                    : Text("Invoegen", comment: "Button that types a snippet without running it")
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { if canRun { run() } }
    }
}

struct SnippetEditorView: View {
    @Bindable var snippet: Snippet
    let host: Host?

    @Environment(\.dismiss) private var dismiss
    @State private var tagText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $snippet.name) {
                        Text("Naam", comment: "Placeholder for a new folder's name")
                    }
                    TextField(text: $snippet.snippetDescription) {
                        Text("Omschrijving", comment: "Field label for a snippet's description")
                    }
                    TextField(text: $tagText) {
                        Text("Labels, door komma's gescheiden", comment: "Field label: comma-separated tags")
                    }
                }

                Section {
                    TextEditor(text: $snippet.command)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } header: {
                    Text("Opdracht", comment: "Section header for a snippet's command")
                } footer: {
                    Text("Met {{naam}} vraagt sssH om een waarde. {{naam=standaard}} vult er alvast een in. Accolades in shell-scripts blijven gewoon staan.",
                         comment: "Explains the snippet placeholder syntax")
                }

                if !snippet.parameters.isEmpty {
                    Section {
                        ForEach(snippet.parameters) { parameter in
                            LabeledContent {
                                Text(verbatim: parameter.defaultValue ?? "—")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(verbatim: parameter.name)
                                    .font(.body.monospaced())
                            }
                        }
                    } header: {
                        Text("Invulvelden", comment: "Section header listing a snippet's placeholders")
                    }
                }

                Section {
                    Toggle(isOn: $snippet.runsImmediately) {
                        Text("Direct uitvoeren", comment: "Toggle: send a newline after the snippet")
                    }

                    if let host {
                        Toggle(isOn: Binding(
                            get: { snippet.host != nil },
                            set: { snippet.host = $0 ? host : nil }
                        )) {
                            Text("Alleen op deze host", comment: "Marks a snippet as host-specific")
                        }
                    }
                } footer: {
                    Text("Staat 'direct uitvoeren' uit, dan wordt de opdracht alleen getypt. Handig voor iets dat je eerst nog wilt nalezen.",
                         comment: "Explains what turning off immediate execution does")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Fragment", comment: "Title of the snippet editor"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        snippet.tags = tagText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        snippet.updatedAt = Date()
                        dismiss()
                    } label: {
                        Text("Gereed", comment: "Button that closes the shell integration sheet")
                    }
                }
            }
            .onAppear { tagText = snippet.tags.joined(separator: ", ") }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }
}

/// Asks for a snippet's placeholders, and shows what will actually be sent.
///
/// The preview is the point. A snippet is a command that runs on a machine the
/// user is not looking at the shell of, and showing the final text before it
/// goes is the difference between a shortcut and a gamble.
struct SnippetParameterPrompt: View {
    let snippet: Snippet
    let send: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(snippet.parameters) { parameter in
                        LabeledContent {
                            TextField(text: binding(for: parameter)) {
                                Text(verbatim: parameter.name)
                            }
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        } label: {
                            Text(verbatim: parameter.name)
                                .font(.body.monospaced())
                        }
                    }
                } header: {
                    Text("Invulvelden", comment: "Section header listing a snippet's placeholders")
                }

                Section {
                    Text(verbatim: snippet.template.expanded(with: values))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Wordt verstuurd", comment: "Section header showing the expanded snippet")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: snippet.name.isEmpty ? snippet.command : snippet.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text("Annuleer", comment: "Cancel button")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send(values)
                        dismiss()
                    } label: {
                        snippet.runsImmediately
                            ? Text("Uitvoeren", comment: "Button that sends a snippet and runs it")
                            : Text("Invoegen", comment: "Button that types a snippet without running it")
                    }
                }
            }
            .onAppear {
                for parameter in snippet.parameters {
                    values[parameter.name] = parameter.defaultValue ?? ""
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private func binding(for parameter: SnippetTemplate.Parameter) -> Binding<String> {
        Binding(
            get: { values[parameter.name] ?? parameter.defaultValue ?? "" },
            set: { values[parameter.name] = $0 }
        )
    }
}
