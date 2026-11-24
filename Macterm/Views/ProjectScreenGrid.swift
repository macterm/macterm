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
    static let spacing: CGFloat = 12

    /// The cards in the order of the sidebar: the tabs in tab order, then
    /// the child projects in the order that `children` has
    /// (`ProjectStore.children(of:)`, by `sortOrder`).
    static func cards(tabs: [TerminalTab], children: [Project]) -> [ProjectScreenCard] {
        tabs.map(ProjectScreenCard.tab) + children.map(ProjectScreenCard.project)
    }

    /// The size of every card for a grid of `width`, at `aspect` (width over
    /// height of the terminal area).
    static func cardSize(width: CGFloat, aspect: CGFloat) -> CGSize {
        let cardWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return CGSize(width: cardWidth, height: cardWidth / max(aspect, 0.2))
    }

    /// How much lower the second column starts.
    static func stagger(cardSize: CGSize) -> CGFloat {
        cardSize.height / 2
    }

    /// The top-left corner of card `index`: the first card left, the second
    /// right, and so on.
    static func origin(of index: Int, cardSize: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        return CGPoint(
            x: CGFloat(column) * (cardSize.width + spacing),
            y: CGFloat(row) * (cardSize.height + spacing) + (column == 0 ? 0 : stagger(cardSize: cardSize))
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
        ScrollView(.vertical) {
            StaggeredCardGrid(aspect: aspect) {
                ForEach(cards) { card in
                    ProjectScreenCardView(card: card, aspect: aspect) { open(card) }
                }
            }
            .padding(32)
        }
        .scrollIndicators(.automatic)
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

/// One card: a rounded rectangle on the theme's surface fill with a thin
/// border. The hover is the tab switcher's selection fill around it.
private struct ProjectScreenCardView: View {
    let card: ProjectScreenCard
    let aspect: CGFloat
    let action: () -> Void

    @State
    private var isHovered = false

    private static let cornerRadius: CGFloat = 8
    /// The space around the card that the hover fill shows in, as in the tab
    /// switcher (`TabSwitcherCard.selectionHalo`).
    private static let halo: CGFloat = 4

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MactermTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(MactermTheme.border.opacity(0.6), lineWidth: 1)
                )
                .padding(Self.halo)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius + Self.halo, style: .continuous)
                        .fill(isHovered ? MactermTheme.fg.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RowHoverTracker(isHovered: $isHovered))
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case let .tab(tab):
            GeometryReader { geo in
                TabPreviewMosaic(node: tab.splitRoot)
                    .frame(size: ProjectScreenGridLayout.fitted(aspect: aspect, in: geo.size))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        case let .project(child):
            VStack(alignment: .leading, spacing: 4) {
                Text(child.name)
                    .font(.system(size: 13, weight: .semibold))
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
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The tab's title for a tab's card, which shows no text. A child's
    /// card reads its name and folder.
    private var accessibilityLabel: String {
        switch card {
        case let .tab(tab): tab.sidebarRowTitle
        case let .project(child): child.hasFolder ? "\(child.name), \(child.path)" : child.name
        }
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
        private var observer: NSObjectProtocol?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        /// Asynchronous: AppKit can attach the view inside a SwiftUI update
        /// pass, where a state change is not allowed (`WindowAttachmentView`).
        private func report() {
            let isVisible = window?.occlusionState.contains(.visible) ?? false
            DispatchQueue.main.async { [weak self] in self?.onChange?(isVisible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
