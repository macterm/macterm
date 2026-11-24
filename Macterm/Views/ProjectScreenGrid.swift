import AppKit
import SwiftUI

/// One card of the project screen's grid: a tab of the project, or a child
/// project.
enum ProjectScreenCard: Identifiable {
    case tab(TerminalTab)
    case project(Project)

    var id: UUID {
        switch self {
        case let .tab(tab): tab.id
        case let .project(project): project.id
        }
    }
}

/// The geometry of the project screen's grid: two columns of cards of one
/// size, the second column lower by half a card, filled row by row.
///
/// All cards have one size. Every tab of a window fills the same terminal
/// area, so every tab has the same aspect, and a child project's card takes
/// that size too.
enum ProjectScreenGridLayout {
    static let columns = 2
    /// The gap between two cards, in both directions.
    static let spacing: CGFloat = 20
    /// The part of the screen's width that the grid takes, padding included.
    static let screenShare: CGFloat = 0.55
    /// The width that the left side (name, path, keys) keeps at the least.
    static let infoMinWidth: CGFloat = 360
    /// The space around the cards: a gap to the left side, and space to the
    /// window's edge and its scroller.
    static let padding = EdgeInsets(top: 40, leading: 24, bottom: 40, trailing: 48)
    /// The narrowest card that the grid shows. A narrower screen shows no
    /// grid, not a narrow strip.
    static let minCardWidth: CGFloat = 160
    /// The rim of card fill around a tab's preview, the same on each side.
    static let inset: CGFloat = 8

    /// The width of the grid, padding included, on a screen of `screenWidth`.
    static func gridWidth(screenWidth: CGFloat) -> CGFloat {
        max(0, min(screenWidth * screenShare, screenWidth - infoMinWidth))
    }

    /// The width of the cards' area in a grid of `gridWidth`.
    static func contentWidth(gridWidth: CGFloat) -> CGFloat {
        max(0, gridWidth - padding.leading - padding.trailing)
    }

    /// The width of one card in a cards' area of `width`.
    static func cardWidth(width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// Whether a screen of `screenWidth` has room for the grid.
    static func showsGrid(screenWidth: CGFloat) -> Bool {
        cardWidth(width: contentWidth(gridWidth: gridWidth(screenWidth: screenWidth))) >= minCardWidth
    }

    /// The corner radius of a card of `width`: round as the reference image,
    /// in proportion to the card.
    static func cornerRadius(cardWidth: CGFloat) -> CGFloat {
        min(max(cardWidth * 0.08, 12), 28)
    }

    /// The cards in the order of the sidebar: the tabs in tab order, then
    /// the child projects in the order that `children` has
    /// (`ProjectStore.children(of:)`, by `sortOrder`).
    static func cards(tabs: [TerminalTab], children: [Project]) -> [ProjectScreenCard] {
        tabs.map(ProjectScreenCard.tab) + children.map(ProjectScreenCard.project)
    }

    /// The size of every card for a cards' area of `width`, at `aspect`
    /// (width over height of the terminal area): a preview of `aspect` with
    /// a rim of `inset` on each side.
    static func cardSize(width: CGFloat, aspect: CGFloat) -> CGSize {
        let cardWidth = cardWidth(width: width)
        let preview = max(0, cardWidth - inset * 2)
        return CGSize(width: cardWidth, height: preview / max(aspect, 0.2) + inset * 2)
    }

    /// The top-left corner of card `index`: the first card left, the second
    /// right, and so on. The second column starts half a card lower.
    static func origin(of index: Int, cardSize: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        return CGPoint(
            x: CGFloat(column) * (cardSize.width + spacing),
            y: CGFloat(row) * (cardSize.height + spacing) + (column == 0 ? 0 : cardSize.height / 2)
        )
    }

    /// The height of a grid of `count` cards: the bottom of the lowest card.
    static func height(count: Int, cardSize: CGSize) -> CGFloat {
        (0 ..< count).map { origin(of: $0, cardSize: cardSize).y + cardSize.height }.max() ?? 0
    }

    /// The largest size of `aspect` that fits in `size`, for a preview in its
    /// card: fitted, never stretched.
    static func fitted(aspect: CGFloat, in size: CGSize) -> CGSize {
        let aspect = max(aspect, 0.2)
        guard size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }
}

/// The grid on the right side of the project screen (`EmptyProjectView`).
///
/// A tab's card is the live preview of the tab, drawn with the tab
/// switcher's mosaic (`TabPreviewMosaic`). A child project's card shows its
/// name and folder. A click on a tab's card shows the tab, and a click on a
/// child's card shows that project's screen.
///
/// The previews are live only while the screen shows and its window is
/// visible (`WindowVisibilityReader`): `AppState.showProjectScreenPreviews`
/// then wakes the tabs' renderers, and `endProjectScreenPreviews` parks them
/// when the screen goes or the window is hidden.
struct ProjectScreenGrid: View {
    let project: Project
    let cards: [ProjectScreenCard]
    /// The height of the screen. A grid that is not as tall is centered.
    let height: CGFloat
    /// Width over height of the terminal area: the area of the project screen.
    let aspect: CGFloat

    @Environment(AppState.self)
    private var appState
    @Environment(WindowState.self)
    private var windowState

    @State
    private var windowIsVisible = false

    private var tabs: [TerminalTab] {
        cards.compactMap { card in
            if case let .tab(tab) = card { return tab }
            return nil
        }
    }

    /// What decides which panes the screen keeps awake.
    private struct SamplingKey: Equatable {
        let isVisible: Bool
        let paneIDs: [UUID]
    }

    private var samplingKey: SamplingKey {
        SamplingKey(isVisible: windowIsVisible, paneIDs: tabs.flatMap { $0.splitRoot.allPanes().map(\.id) })
    }

    var body: some View {
        // The cards take the width that the scroll view gives, so a scroller
        // that takes space never eats into the padding. `StaggeredCardGrid`
        // reports the height of that same width, so the last card is never
        // cut and a grid that fits does not scroll.
        ScrollView(.vertical) {
            StaggeredCardGrid(aspect: aspect) {
                ForEach(cards) { card in
                    ProjectScreenCardView(card: card, aspect: aspect) { open(card) }
                }
            }
            .padding(ProjectScreenGridLayout.padding)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(WindowVisibilityReader { windowIsVisible = $0 })
        .onChange(of: samplingKey, initial: true) { _, key in
            if key.isVisible {
                appState.showProjectScreenPreviews(of: tabs, in: windowState)
            } else {
                appState.endProjectScreenPreviews(in: windowState)
            }
        }
        .onDisappear { appState.endProjectScreenPreviews(in: windowState) }
    }

    private func open(_ card: ProjectScreenCard) {
        switch card {
        case let .tab(tab):
            appState.selectTab(tab.id, projectID: project.id, in: windowState)
        case let .project(child):
            appState.showProjectScreen(child, in: windowState)
        }
    }
}

/// Places its children as `ProjectScreenGridLayout` says, at the width that
/// it is given. Every child gets the one card size.
private struct StaggeredCardGrid: Layout {
    let aspect: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let card = ProjectScreenGridLayout.cardSize(width: width, aspect: aspect)
        return CGSize(width: width, height: ProjectScreenGridLayout.height(count: subviews.count, cardSize: card))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let card = ProjectScreenGridLayout.cardSize(width: bounds.width, aspect: aspect)
        for (index, subview) in subviews.enumerated() {
            let origin = ProjectScreenGridLayout.origin(of: index, cardSize: card)
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(card)
            )
        }
    }
}

/// One card: a rounded rectangle with a soft fill and a thin border, as in
/// the reference image. A tab's preview sits inside it, inset by
/// `ProjectScreenGridLayout.inset`, with corners that follow the card's. The
/// hover is the tab switcher's selection fill around it.
private struct ProjectScreenCardView: View {
    let card: ProjectScreenCard
    let aspect: CGFloat
    let action: () -> Void

    @State
    private var isHovered = false

    var body: some View {
        // `StaggeredCardGrid` proposes the card's exact size.
        GeometryReader { geo in
            cardButton(size: geo.size)
        }
    }

    private static let inset = ProjectScreenGridLayout.inset

    /// How far the hover fill reaches out of the card, as in the tab
    /// switcher (`TabSwitcherCard.selectionHalo`). It is drawn in the gap
    /// between cards, so the card keeps the size of its slot and its aspect.
    private static let halo: CGFloat = 4

    private func cardButton(size: CGSize) -> some View {
        let cornerRadius = ProjectScreenGridLayout.cornerRadius(cardWidth: size.width)
        return Button(action: action) {
            content(size: size, cornerRadius: cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MactermTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(MactermTheme.border, lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius + Self.halo, style: .continuous)
                        .fill(isHovered ? MactermTheme.fg.opacity(0.14) : .clear)
                        .padding(-Self.halo)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RowHoverTracker(isHovered: $isHovered))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func content(size: CGSize, cornerRadius: CGFloat) -> some View {
        switch card {
        case let .tab(tab):
            let inner = CGSize(width: max(0, size.width - Self.inset * 2), height: max(0, size.height - Self.inset * 2))
            TabPreviewMosaic(node: tab.splitRoot)
                .frame(size: ProjectScreenGridLayout.fitted(aspect: aspect, in: inner))
                .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - Self.inset, 4), style: .continuous))
                .frame(size: inner)
        case let .project(child):
            VStack(alignment: .leading, spacing: 6) {
                Text(child.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MactermTheme.fg)
                    .lineLimit(2)
                if child.hasFolder {
                    Text(verbatim: child.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MactermTheme.fgMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding(cornerRadius * 0.75)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The tab's title for a tab's card, which shows no text. The child's
    /// name for a child's card.
    private var accessibilityLabel: String {
        switch card {
        case let .tab(tab): tab.sidebarRowTitle
        case let .project(child): child.name
        }
    }

    /// The child's folder, if it has one.
    private var accessibilityValue: String {
        if case let .project(child) = card, child.hasFolder { return child.path }
        return ""
    }
}

private extension View {
    func frame(size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }
}

/// Reports whether the window that holds this view is visible: on screen,
/// not minimized, not covered, the app not hidden
/// (`NSWindow.occlusionState`). False while the view has no window.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context _: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        /// The window this view observes. A selector observer: the center
        /// drops it by itself when the view goes, so no deinit is needed.
        private weak var observedWindow: NSWindow?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                center.addObserver(
                    self, selector: #selector(occlusionDidChange),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window
                )
            }
            report()
        }

        @objc
        private func occlusionDidChange(_: Notification) {
            // Before the read: the order of two observers of one
            // notification is not defined (`WindowOcclusionReports`).
            if let window { WindowOcclusionReports.noteReport(from: window) }
            report()
        }

        /// Asynchronous: AppKit can attach the view inside a SwiftUI update
        /// pass, where a state change is not allowed (`WindowAttachmentView`).
        private func report() {
            // A new window's occlusion state is wrong until its first report
            // (`WindowOcclusionReports`): until then, an ordered-in window counts.
            let isVisible = window.map {
                WindowOcclusionReports.hasReported($0) ? $0.occlusionState.contains(.visible) : $0.isVisible
            } ?? false
            DispatchQueue.main.async { [weak self] in self?.onChange?(isVisible) }
        }
    }
}
