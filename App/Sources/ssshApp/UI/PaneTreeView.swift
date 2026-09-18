import SwiftUI
import ssshCore

/// Renders a tab's ``PaneLayout`` as nested split views.
///
/// Recursive, mirroring the tree, so a split is laid out relative to the space
/// its parent gave it and nothing needs to compute absolute frames.
struct PaneTreeView: View {
    let tab: TerminalTab
    let layout: PaneLayout

    var body: some View {
        switch layout {
        case .terminal(let pane):
            if let session = tab.panes[pane] {
                TerminalPane(session: session, tab: tab, pane: pane)
                    .overlay(alignment: .topTrailing) {
                        // Only worth pointing out which pane is focused when
                        // there is more than one.
                        if tab.paneCount > 1, tab.focusedPane == pane {
                            FocusedPaneIndicator()
                        }
                    }
                    .onTapGesture { tab.focusedPane = pane }
            } else {
                Color.clear
            }

        case .split(let split):
            SplitContainer(tab: tab, split: split)
        }
    }
}

/// One split, with a draggable divider.
private struct SplitContainer: View {
    let tab: TerminalTab
    let split: PaneLayout.Split

    @State private var dragStartFraction: Double?

    private let dividerThickness: CGFloat = 1
    /// The divider is one point wide but grabbable well beyond that: a
    /// one-point hit target is unusable with a trackpad and impossible with a
    /// finger.
    private let dividerHitWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let total = split.axis == .horizontal ? geometry.size.width : geometry.size.height
            let firstExtent = max(0, total * split.fraction - dividerThickness / 2)
            let secondExtent = max(0, total - firstExtent - dividerThickness)

            layoutStack {
                PaneTreeView(tab: tab, layout: split.first)
                    .frame(
                        width: split.axis == .horizontal ? firstExtent : nil,
                        height: split.axis == .vertical ? firstExtent : nil
                    )

                divider(total: total)

                PaneTreeView(tab: tab, layout: split.second)
                    .frame(
                        width: split.axis == .horizontal ? secondExtent : nil,
                        height: split.axis == .vertical ? secondExtent : nil
                    )
            }
        }
    }

    @ViewBuilder
    private func layoutStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if split.axis == .horizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(
                width: split.axis == .horizontal ? dividerThickness : nil,
                height: split.axis == .vertical ? dividerThickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(
                        width: split.axis == .horizontal ? dividerHitWidth : nil,
                        height: split.axis == .vertical ? dividerHitWidth : nil
                    )
                    .gesture(dragGesture(total: total))
                    #if os(macOS)
                    .onHover { inside in
                        // The cursor is the only affordance a one-point line has.
                        if inside {
                            split.axis == .horizontal
                                ? NSCursor.resizeLeftRight.push()
                                : NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    #endif
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Scheiding", comment: "Accessibility label for a split divider"))
            .accessibilityValue(Text("\(Int(split.fraction * 100)) procent",
                                     comment: "Accessibility value: the divider position as a percentage"))
            .accessibilityAdjustableAction { direction in
                // Keyboard and VoiceOver users need to move a divider too, and
                // a drag gesture is not reachable by either.
                let step = 0.05
                let delta = direction == .increment ? step : -step
                tab.setDivider(split.fraction + delta, forSplit: split.id)
            }
    }

    private func dragGesture(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard total > 0 else { return }
                // The fraction at the start of the drag is the reference, so
                // the divider tracks the pointer instead of drifting when
                // updates are coalesced.
                let start = dragStartFraction ?? split.fraction
                dragStartFraction = start

                let travelled = split.axis == .horizontal ? value.translation.width : value.translation.height
                tab.setDivider(start + travelled / total, forSplit: split.id)
            }
            .onEnded { _ in
                dragStartFraction = nil
            }
    }
}

private struct FocusedPaneIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.tint)
            .frame(width: 24, height: 3)
            .padding(6)
            .accessibilityHidden(true)
    }
}
