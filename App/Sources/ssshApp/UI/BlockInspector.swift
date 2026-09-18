import SwiftUI
import UniformTypeIdentifiers
import ssshCore

/// The commands run in the focused pane, as a list you can search and act on.
///
/// This is a navigation aid, not a second terminal: the terminal is still the
/// place output is read. What the list adds is the thing a scrollback cannot
/// answer — which command produced this, did it fail, and how long did it take.
struct BlockInspector: View {
    let feed: any TerminalFeed

    var body: some View {
        @Bindable var blocks = feed.blocks

        VStack(spacing: 0) {
            BlockInspectorHeader(blocks: blocks)
            Divider()

            if blocks.blocks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nog geen opdrachten", comment: "Empty state title for the command block list")
                    } icon: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                } description: {
                    Text("Zodra je iets uitvoert verschijnt het hier.",
                         comment: "Empty state body for the command block list")
                }
            } else if blocks.visibleBlocks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Geen resultaten", comment: "Empty state title when a block filter matches nothing")
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                } description: {
                    Text("Geen opdracht in deze sessie komt overeen.",
                         comment: "Empty state body when a block filter matches nothing")
                }
            } else {
                blockList(blocks)
            }

            if !blocks.hasShellIntegration {
                Divider()
                ShellIntegrationHint()
            }
        }
        .frame(minWidth: 280)
    }

    private func blockList(_ blocks: SessionBlocks) -> some View {
        ScrollViewReader { proxy in
            List {
                // Newest at the top: in a session of any length, the command
                // you want is the one you just ran.
                ForEach(blocks.visibleBlocks.reversed()) { block in
                    BlockRow(block: block, isExpanded: blocks.selection == block.id) {
                        rerun(block)
                    }
                    .id(block.id)
                    .contentShape(Rectangle())
                    // A tap rather than `List(selection:)`: on iOS that
                    // binding only responds in edit mode, so half the
                    // platforms would have an inert list.
                    .onTapGesture {
                        blocks.selection = blocks.selection == block.id ? nil : block.id
                    }
                }
            }
            .listStyle(.inset)
            .onChange(of: blocks.selection) { _, selection in
                guard let selection else { return }
                withAnimation { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private func rerun(_ block: CommandBlock) {
        guard !block.command.isEmpty else { return }
        feed.send(ArraySlice(Array(block.command.utf8) + [0x0D]))
    }
}

private struct BlockInspectorHeader: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var blocks: SessionBlocks
    @FocusState private var searchIsFocused: Bool
    @State private var exportsLog = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(text: $blocks.query) {
                    Text("Zoek in deze sessie", comment: "Placeholder in the in-session search field")
                }
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif

                if !blocks.query.isEmpty {
                    Button {
                        blocks.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Wis zoekopdracht", comment: "Accessibility label for the clear-search button"))
                }

                Button {
                    exportsLog = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(blocks.blocks.isEmpty)
                .accessibilityLabel(Text("Exporteer sessielog", comment: "Accessibility label for the session log export button"))
            }

            if !blocks.matches.isEmpty {
                MatchStepper(blocks: blocks)
            }

            Picker(selection: $blocks.filter.outcome) {
                Text("Alles", comment: "Block filter: show every command").tag(CommandBlockFilter.Outcome.all)
                Text("Mislukt", comment: "Block filter: show only commands that reported a non-zero exit status")
                    .tag(CommandBlockFilter.Outcome.failed)
                Text("Loopt", comment: "Block filter: show only commands still running")
                    .tag(CommandBlockFilter.Outcome.running)
            } label: {
                Text("Filter", comment: "Accessibility label for the block outcome filter")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(10)
        // Command-F both opens the list and asks for this field, so the
        // request has to be honoured whether the header already existed or is
        // appearing because of it.
        .onAppear(perform: takeRequestedFocus)
        .onChange(of: environment.pendingBlockSearchFocus) { _, isPending in
            if isPending { takeRequestedFocus() }
        }
        // The whole list, not the filtered view: an export is a record, and a
        // record that silently honoured a filter would look complete and not
        // be. The filter is visible on screen; it is not visible in a file.
        .fileExporter(
            isPresented: $exportsLog,
            document: PlainTextDocument(text: SessionLogText.render(blocks.blocks)),
            contentType: .plainText,
            defaultFilename: String(localized: "sessielog", comment: "Default filename for an exported session log")
        ) { _ in }
    }

    private func takeRequestedFocus() {
        guard environment.pendingBlockSearchFocus else { return }
        environment.pendingBlockSearchFocus = false
        searchIsFocused = true
    }
}

/// Steps through the lines the query matched.
///
/// The filtered list answers "which commands match"; this answers "show me the
/// next place it matched", which is the question someone scanning a build log
/// is actually asking.
private struct MatchStepper: View {
    let blocks: SessionBlocks
    @State private var index = 0

    var body: some View {
        HStack(spacing: 6) {
            matchDescription
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel(Text("Vorige treffer", comment: "Accessibility label for the previous search result button"))
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(Text("Volgende treffer", comment: "Accessibility label for the next search result button"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        // A new set of results is a new search: starting at hit 4 of 5 would
        // skip the ones the user is most likely to want.
        .onChange(of: blocks.matches.count) { _, _ in index = 0 }
        .onAppear { select() }
    }

    private var matchDescription: Text {
        Text("Treffer \(index + 1) van \(blocks.matches.count)",
             comment: "Search result position, as 'hit N of M'")
    }

    private func step(_ delta: Int) {
        guard !blocks.matches.isEmpty else { return }
        // Wrapping rather than stopping: a search that refuses to go round is
        // a search you have to keep looking at to use.
        index = (index + delta + blocks.matches.count) % blocks.matches.count
        select()
    }

    private func select() {
        guard blocks.matches.indices.contains(index) else { return }
        blocks.selection = blocks.matches[index].blockID
    }
}

/// One command, with its outcome and — when selected — its output.
private struct BlockRow: View {
    let block: CommandBlock
    let isExpanded: Bool
    let rerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BlockOutcomeIcon(block: block)

                Text(block.command.isEmpty ? String(localized: "(geen opdracht)", comment: "Placeholder for a block whose command could not be recovered") : block.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(isExpanded ? nil : 1)

                Spacer(minLength: 0)

                if let duration = block.duration, duration >= 1 {
                    Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                BlockOutputView(block: block)
            } else if let preview = previewLine {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The last non-empty line. For a failed command that is usually the error,
    /// which is the whole reason to show a preview at all.
    private var previewLine: String? {
        block.outputLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            Pasteboard.copy(block.command)
        } label: {
            Label {
                Text("Kopieer opdracht", comment: "Menu item that copies a block's command")
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
        .disabled(block.command.isEmpty)

        Button {
            Pasteboard.copy(block.outputText)
        } label: {
            Label {
                Text("Kopieer uitvoer", comment: "Menu item that copies a block's output")
            } icon: {
                Image(systemName: "doc.on.clipboard")
            }
        }
        .disabled(block.output.isEmpty)

        Button(action: rerun) {
            Label {
                Text("Voer opnieuw uit", comment: "Menu item that runs a block's command again")
            } icon: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(block.command.isEmpty)

        ShareLink(item: shareText) {
            Label {
                Text("Deel", comment: "Menu item that shares a block as text")
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    private var shareText: String {
        let output = block.outputText
        return output.isEmpty ? block.command : "\(block.command)\n\(output)"
    }

    private var accessibilityLabel: Text {
        switch block.state {
        case .prompting:
            return Text("Wacht op invoer", comment: "Accessibility label for a block at a prompt")
        case .running:
            return Text("\(block.command), loopt nog", comment: "Accessibility label for a running command block")
        case .finished(let status):
            guard let status else {
                return Text("\(block.command), afgerond, afsluitcode onbekend",
                            comment: "Accessibility label for a finished block with no reported exit status")
            }
            return status == 0
                ? Text("\(block.command), gelukt", comment: "Accessibility label for a successful command block")
                : Text("\(block.command), mislukt met code \(Int(status))",
                       comment: "Accessibility label for a failed command block, with its exit status")
        }
    }
}

/// The outcome, in shape and colour rather than colour alone.
///
/// Hidden from VoiceOver: the row's own label already says "succeeded",
/// "failed with status 2" or "exit status unknown" in words, and the glyph
/// would be a second announcement of the same fact.
private struct BlockOutcomeIcon: View {
    let block: CommandBlock

    var body: some View {
        icon.accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch block.state {
        case .prompting:
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .finished(let status):
            if let status {
                Image(systemName: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? Color.green : Color.red)
            } else {
                // No status was reported. That is not success, and drawing a
                // green tick here would be a lie the user would rely on.
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BlockOutputView: View {
    let block: CommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if block.output.isEmpty {
                Text("Geen uitvoer", comment: "Shown when an expanded block produced no output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(Self.linkified(block.outputText))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }

            if block.outputTruncated {
                Label {
                    Text("Niet alle uitvoer is bewaard.",
                         comment: "Warning shown on a block whose output was capped or skipped")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// URLs in the output become tappable links.
    ///
    /// Detection rather than markup, because remote output is plain text by
    /// the time the block scanner has it. The scheme allowlist is the same
    /// one the terminal's OSC 8 handler applies, and for the same reason: a
    /// remote host can print anything, and handing an arbitrary scheme to the
    /// system opener would let it launch things.
    private static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard text.contains("://") || text.contains("www.") || text.contains("@"),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return attributed
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme),
                  let stringRange = Range(match.range, in: text),
                  let range = Range(stringRange, in: attributed)
            else { continue }
            attributed[range].link = url
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}

/// The block list as a text file: commands, their output, their exit status.
private enum SessionLogText {
    static func render(_ blocks: [CommandBlock]) -> String {
        blocks.map { block in
            var lines: [String] = ["$ \(block.command)"]
            let output = block.outputText
            if !output.isEmpty { lines.append(output) }
            if case .finished(let status) = block.state, let status, status != 0 {
                lines.append("[afsluitcode \(status)]")
            }
            if block.outputTruncated {
                // The on-screen list carries this warning; the file has to
                // carry it too or it claims completeness it does not have.
                lines.append("[uitvoer onvolledig]")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}

private struct PlainTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Offered, never imposed. sssh cannot make a remote shell emit markers, and it
/// will not edit someone's rc file for them.
private struct ShellIntegrationHint: View {
    @State private var showsSheet = false

    var body: some View {
        Button {
            showsSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("Betere blokken met shell-integratie",
                     comment: "Button offering to show the shell integration snippet")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsSheet) {
            ShellIntegrationView()
        }
    }
}
