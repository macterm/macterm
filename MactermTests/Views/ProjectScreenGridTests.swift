import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectScreenGridTests {
    private func tab() -> TerminalTab {
        let pane = Pane(projectPath: "/p", projectID: UUID())
        return TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
    }

    private func store() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-grid-\(UUID().uuidString).json"))
    }

    @Test
    func every_card_has_one_size_from_the_column_width_and_the_aspect() {
        let size = ProjectScreenGridLayout.cardSize(width: 412, aspect: 2)
        // Two columns with one 12 pt gap.
        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test
    func the_cards_fill_row_by_row_and_the_second_column_starts_half_a_card_lower() {
        let size = CGSize(width: 200, height: 100)
        #expect(ProjectScreenGridLayout.origin(of: 0, cardSize: size) == .zero)
        #expect(ProjectScreenGridLayout.origin(of: 1, cardSize: size) == CGPoint(x: 212, y: 50))
        #expect(ProjectScreenGridLayout.origin(of: 2, cardSize: size) == CGPoint(x: 0, y: 112))
        #expect(ProjectScreenGridLayout.origin(of: 3, cardSize: size) == CGPoint(x: 212, y: 162))
        // The lowest card is the last of the second column.
        #expect(ProjectScreenGridLayout.height(count: 4, cardSize: size) == 262)
        #expect(ProjectScreenGridLayout.height(count: 3, cardSize: size) == 212)
        #expect(ProjectScreenGridLayout.height(count: 0, cardSize: size) == 0)
    }

    @Test
    func a_preview_is_fitted_in_its_card_and_never_stretched() {
        let card = CGSize(width: 200, height: 100)
        #expect(ProjectScreenGridLayout.fitted(aspect: 2, in: card) == card)
        // Wider than the card: full width, less height.
        #expect(ProjectScreenGridLayout.fitted(aspect: 4, in: card) == CGSize(width: 200, height: 50))
        // Taller than the card: full height, less width.
        #expect(ProjectScreenGridLayout.fitted(aspect: 1, in: card) == CGSize(width: 100, height: 100))
        #expect(ProjectScreenGridLayout.fitted(aspect: 1, in: .zero) == .zero)
    }

    @Test
    func the_tabs_come_first_in_tab_order_then_the_children_in_sidebar_order() {
        let tabs = [tab(), tab(), tab()]
        let store = store()
        let parent = store.create(name: "parent", path: "/p")
        let second = store.create(name: "second", path: "/p/second")
        let first = store.create(name: "first", path: "")
        store.move(second.id, into: parent.id)
        store.move(first.id, into: parent.id)
        store.reorder(parent: parent.id, ids: [first.id, second.id])

        let cards = ProjectScreenGridLayout.cards(tabs: tabs, children: store.children(of: parent.id))

        #expect(cards.map(\.id) == tabs.map(\.id) + [first.id, second.id])
        guard case let .project(noFolder) = cards[3] else {
            Issue.record("expected a child card")
            return
        }
        // A child with no folder has no path line.
        #expect(!noFolder.hasFolder)
    }

    @Test
    func a_project_with_no_tabs_and_no_children_has_no_cards() {
        #expect(ProjectScreenGridLayout.cards(tabs: [], children: []).isEmpty)
    }
}
