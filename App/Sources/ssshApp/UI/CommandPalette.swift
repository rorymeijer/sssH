import SwiftData
import SwiftUI
import ssshCore

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    enum Kind {
        case host(Host)
        case action
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String?
    var symbol: String
    /// Extra words that should match but are not shown: a host's tags, an
    /// action's synonyms. Searching only the visible text makes a palette feel
    /// broken the first time an obvious word fails.
    var keywords: [String] = []
    var perform: () -> Void
}

/// ⌘K. Hosts, and the things you can do to the current session.
///
/// Scored rather than filtered: a prefix match beats a word-start match beats a
/// subsequence, so typing "prod" puts `prod-web-1` above `reproduce-bug`. A
/// palette that lists matches in storage order is a palette people stop using.
@MainActor
@Observable
final class CommandPaletteModel {
    var isPresented = false
    var query = ""
    var selectedIndex = 0

    private(set) var items: [PaletteItem] = []

    func present(with items: [PaletteItem]) {
        self.items = items
        query = ""
        selectedIndex = 0
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        query = ""
        items = []
    }

    var results: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }

        return items
            .compactMap { item -> (item: PaletteItem, score: Int)? in
                guard let score = Self.score(item, query: trimmed) else { return nil }
                return (item, score)
            }
            .sorted { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
                    : lhs.score > rhs.score
            }
            .map(\.item)
    }

    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + offset + count) % count
    }

    func activateSelection() {
        let results = results
        guard results.indices.contains(selectedIndex) else { return }
        let item = results[selectedIndex]
        dismiss()
        item.perform()
    }

    /// Higher is better. `nil` means no match at all.
    ///
    /// The ranking itself lives in `ssshCore` so it can be tested without a
    /// window; this only decides which fields are searched and how much each
    /// is worth.
    static func score(_ item: PaletteItem, query: String) -> Int? {
        let haystacks = [item.title, item.subtitle ?? ""] + item.keywords
        var best: Int?

        for (index, text) in haystacks.enumerated() where !text.isEmpty {
            guard let raw = PaletteScoring.score(text, query: query) else { continue }
            // The title matters more than the subtitle, which matters more than
            // hidden keywords.
            let weighted = raw - index * 5
            best = max(best ?? Int.min, weighted)
        }

        return best
    }
}

struct CommandPaletteView: View {
    /// Scales with the text size. A fixed height shows two rows at the
    /// largest accessibility sizes, which is not a list.
    @ScaledMetric(relativeTo: .body) private var resultsHeight: CGFloat = 180

    @Bindable var model: CommandPaletteModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                    .foregroundStyle(.secondary)
                TextField(text: $model.query) {
                    Text("Ga naar host of voer opdracht uit",
                         comment: "Placeholder in the command palette search field")
                }
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .onSubmit { model.activateSelection() }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            }
            .padding(14)

            Divider()

            if model.results.isEmpty {
                ContentUnavailableView.search(text: model.query)
                    // Scales with the text size: a list with a fixed height
                    // shows two rows at the largest accessibility sizes.
                    .frame(height: resultsHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == model.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectedIndex = index
                                        model.activateSelection()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selectedIndex) { _, index in
                        guard model.results.indices.contains(index) else { return }
                        proxy.scrollTo(model.results[index].id)
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .onChange(of: model.query) { _, _ in
            // A stale selection after the list changes underneath is how a
            // palette runs the wrong thing.
            model.selectedIndex = 0
        }
        #if os(macOS)
        // Arrow keys move the selection without leaving the text field.
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { model.dismiss() }
        #else
        // Those two are AppKit's, and do not exist on iOS. `onKeyPress` does
        // the same job for an iPad with a hardware keyboard attached, and is
        // simply never called without one.
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            model.dismiss()
            return .handled
        }
        #endif
        .accessibilityAddTraits(.isModal)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
