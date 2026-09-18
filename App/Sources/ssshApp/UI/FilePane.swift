import SwiftUI
import UniformTypeIdentifiers
import ssshCore

/// One side of the file browser.
///
/// Both sides use this. The local and remote halves genuinely differ in what
/// they can do — only the remote one has permissions, only the local one has a
/// trash — so the differences are parameters rather than a second view, and
/// the parts that must behave identically cannot drift apart.
struct FilePane: View {
    let title: Text
    let path: String
    let entries: [RemoteFileEntry]
    let isLoading: Bool
    let failure: String?

    @Binding var selection: Set<String>
    @Binding var options: DirectoryListingOptions

    let canGoUp: Bool
    let canGoBack: Bool

    let onOpen: (RemoteFileEntry) -> Void
    let onNavigate: (String) -> Void
    let onUp: () -> Void
    let onBack: () -> Void
    /// Absent on the local side, which has no server-defined home.
    let onHome: (() -> Void)?
    let onReload: () -> Void
    let onNewFolder: () -> Void
    let onRename: (RemoteFileEntry) -> Void
    let onDelete: ([RemoteFileEntry]) -> Void
    /// Absent on the local side: changing a local file's mode from here would
    /// be a footgun with no matching need.
    let onPermissions: ((RemoteFileEntry) -> Void)?
    let onTransfer: ([RemoteFileEntry]) -> Void
    let transferLabel: Text
    let transferSymbol: String

    /// What a drag out of this pane carries.
    let dragPayload: ([RemoteFileEntry]) -> DraggedFiles
    /// A drop from the other pane. Returns false when the drop is not for
    /// this pane — dragging a directory's contents back into the directory
    /// they came from, for instance.
    let onDropSelection: (DraggedFiles) -> Bool
    /// A drop from outside the app: Finder, Files, or another app that vends
    /// file URLs. Absent on the local pane, where the system already does it.
    let onDropURLs: (([URL]) -> Bool)?

    private var selectedEntries: [RemoteFileEntry] {
        entries.filter { selection.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            breadcrumbs
            Divider()

            if let failure {
                ContentUnavailableView {
                    Label {
                        Text("Map kan niet worden geopend", comment: "Title shown when a directory could not be listed")
                    } icon: {
                        Image(systemName: "folder.badge.questionmark")
                    }
                } description: {
                    Text(failure)
                } actions: {
                    Button(action: onReload) {
                        Text("Opnieuw proberen", comment: "Button that retries a failed directory listing")
                    }
                }
            } else {
                list
            }
        }
        .frame(minWidth: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            title.font(.headline)
            if isLoading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)

            Menu {
                Picker(selection: $options.sortKey) {
                    Text("Naam", comment: "Sort files by name").tag(DirectoryListingOptions.SortKey.name)
                    Text("Grootte", comment: "Sort files by size").tag(DirectoryListingOptions.SortKey.size)
                    Text("Gewijzigd", comment: "Sort files by modification date").tag(DirectoryListingOptions.SortKey.modified)
                    Text("Soort", comment: "Sort files by kind").tag(DirectoryListingOptions.SortKey.kind)
                } label: {
                    Text("Sorteren", comment: "Label for the file sort menu")
                }
                Toggle(isOn: $options.ascending) {
                    Text("Oplopend", comment: "Toggle for ascending sort order")
                }
                Divider()
                Toggle(isOn: $options.showsHidden) {
                    // An SSH client is mostly used to look at .ssh, .bashrc and
                    // .config, so this is one toggle away rather than buried.
                    Text("Verborgen bestanden tonen", comment: "Toggle that shows dotfiles")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text("Sorteren", comment: "Label for the file sort menu"))

            Button(action: onNewFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel(Text("Nieuwe map", comment: "Title of the new folder prompt"))

            Button(action: onReload) {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Vernieuwen", comment: "Accessibility label for the refresh button"))
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
            }
            .disabled(!canGoBack)
            .accessibilityLabel(Text("Terug", comment: "Accessibility label for the back button"))

            Button(action: onUp) {
                Image(systemName: "arrow.up")
            }
            .disabled(!canGoUp)
            .accessibilityLabel(Text("Naar bovenliggende map", comment: "Accessibility label for the go-up button"))

            if let onHome {
                Button(action: onHome) {
                    Image(systemName: "house")
                }
                .accessibilityLabel(Text("Naar thuismap", comment: "Accessibility label for the go-home button"))
            }

            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(RemotePath.ancestors(of: path), id: \.path) { ancestor in
                        Button {
                            onNavigate(ancestor.path)
                        } label: {
                            Text(verbatim: ancestor.name)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ancestor.path == path ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                        if ancestor.path != path {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.caption)
            }
            .scrollIndicators(.never)
            // The end of a long path is the part that matters, so that is the
            // end that stays on screen.
            .defaultScrollAnchor(.trailing)

            TextField(text: $options.filter) {
                Text("Filter", comment: "Placeholder for the file list filter field")
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var list: some View {
        // Two shapes on purpose. `List(selection:)` is how a Mac list works —
        // click to select, double-click to open, shift-click for a range — and
        // on iOS that same binding only responds in edit mode, which would
        // leave the phone with a list that does nothing. There, selection is
        // an explicit control on each row.
        #if os(macOS)
        List(selection: $selection) {
            ForEach(entries) { entry in
                row(entry)
                    .tag(entry.name)
                    .onTapGesture(count: 2) { onOpen(entry) }
            }
        }
        .listStyle(.inset)
        .modifier(PaneDrops(onDropSelection: onDropSelection, onDropURLs: onDropURLs))
        .overlay(alignment: .bottom) { transferBar }
        .contextMenu {
            Button(action: onNewFolder) {
                Text("Nieuwe map", comment: "Title of the new folder prompt")
            }
        }
        #else
        List {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Button {
                        toggleSelection(of: entry)
                    } label: {
                        Image(systemName: selection.contains(entry.name) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(entry.name) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Selecteren", comment: "Accessibility label for a row's selection control"))
                    .accessibilityAddTraits(selection.contains(entry.name) ? [.isSelected] : [])

                    row(entry)
                        .onTapGesture {
                            if entry.attributes.kind == .directory || entry.attributes.kind == .symlink {
                                onOpen(entry)
                            } else {
                                toggleSelection(of: entry)
                            }
                        }
                }
            }
        }
        .listStyle(.inset)
        .modifier(PaneDrops(onDropSelection: onDropSelection, onDropURLs: onDropURLs))
        .overlay(alignment: .bottom) { transferBar }
        #endif
    }

    private func toggleSelection(of entry: RemoteFileEntry) {
        if selection.contains(entry.name) {
            selection.remove(entry.name)
        } else {
            selection.insert(entry.name)
        }
    }

    private func row(_ entry: RemoteFileEntry) -> some View {
        FileRow(entry: entry)
            .contentShape(Rectangle())
            .contextMenu { menu(for: entry) }
            // Dragging a row that is part of the selection drags the whole
            // selection; dragging one that is not drags just it. Anything else
            // surprises someone who selected ten files and dragged one.
            .draggable(dragPayload(selection.contains(entry.name) ? selectedEntries : [entry]))
    }

    @ViewBuilder
    private var transferBar: some View {
        if !selection.isEmpty {
            HStack {
                Button {
                    onTransfer(selectedEntries)
                } label: {
                    Label { transferLabel } icon: { Image(systemName: transferSymbol) }
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    onDelete(selectedEntries)
                } label: {
                    Label {
                        Text("Verwijderen", comment: "Button that deletes the selected files")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Text("\(selection.count) geselecteerd", comment: "How many files are selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private func menu(for entry: RemoteFileEntry) -> some View {
        Button { onOpen(entry) } label: {
            Text("Openen", comment: "Menu item that opens a directory")
        }
        .disabled(entry.attributes.kind != .directory && entry.attributes.kind != .symlink)

        Button { onTransfer([entry]) } label: {
            Label { transferLabel } icon: { Image(systemName: transferSymbol) }
        }

        Divider()

        Button { onRename(entry) } label: {
            Text("Naam wijzigen…", comment: "Menu item that renames a file")
        }

        if let onPermissions {
            Button { onPermissions(entry) } label: {
                Text("Rechten…", comment: "Menu item that edits a file's POSIX permissions")
            }
        }

        Button(role: .destructive) { onDelete([entry]) } label: {
            Text("Verwijderen", comment: "Button that deletes the selected files")
        }
    }
}

/// The two kinds of drop a pane accepts.
///
/// Stacked rather than combined into one `Transferable`, because they carry
/// genuinely different things — a selection from the other pane in this app,
/// and file URLs from outside it — and each destination ignores a session that
/// is not its own type.
private struct PaneDrops: ViewModifier {
    let onDropSelection: (DraggedFiles) -> Bool
    let onDropURLs: (([URL]) -> Bool)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onDropURLs {
            content
                .dropDestination(for: DraggedFiles.self) { items, _ in items.map(onDropSelection).contains(true) }
                .dropDestination(for: URL.self) { urls, _ in onDropURLs(urls) }
        } else {
            content
                .dropDestination(for: DraggedFiles.self) { items, _ in items.map(onDropSelection).contains(true) }
        }
    }
}

/// One row: icon, name, size, date, mode.
private struct FileRow: View {
    let entry: RemoteFileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(entry.attributes.kind == .directory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)

            Text(verbatim: entry.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if entry.attributes.kind != .directory, let size = entry.attributes.size {
                Text(verbatim: FileTransferText.formatBytes(size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let modified = entry.attributes.modifiedAt {
                Text(modified, format: .dateTime.year().month().day())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)
            }

            if let permissions = entry.attributes.permissions {
                Text(verbatim: permissions.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch entry.attributes.kind {
        case .directory: return "folder"
        case .symlink: return "arrow.turn.up.right"
        case .file: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }

    private var accessibilityLabel: Text {
        switch entry.attributes.kind {
        case .directory:
            return Text("Map \(entry.name)", comment: "Accessibility label for a directory row")
        case .symlink:
            return Text("Symbolische koppeling \(entry.name)", comment: "Accessibility label for a symlink row")
        case .file, .other:
            guard let size = entry.attributes.size else {
                return Text("Bestand \(entry.name)", comment: "Accessibility label for a file row without a known size")
            }
            return Text("Bestand \(entry.name), \(FileTransferText.formatBytes(size))",
                        comment: "Accessibility label for a file row, with its size")
        }
    }
}
