import AppKit
import Foundation
@testable import Macterm
import Testing
import UniformTypeIdentifiers

@MainActor
struct PinDragPresenceTests {
    @Test
    func a_drag_that_moves_from_the_rows_to_a_header_keeps_the_band_open() async {
        let presence = PinDragPresence()
        presence.set(.rows, holds: true)
        #expect(presence.isActive)
        // One drag update: the rows let go, then a header takes the drag.
        presence.set(.rows, holds: false)
        presence.set(.header(UUID()), holds: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(presence.isActive)
    }

    @Test
    func the_band_closes_after_the_last_view_lets_go() async {
        let presence = PinDragPresence()
        let header = UUID()
        presence.set(.header(header), holds: true)
        presence.set(.strip, holds: true)
        presence.set(.header(header), holds: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(presence.isActive)
        presence.set(.strip, holds: false)
        #expect(await poll { presence.isActive ? nil : true } == true)
    }

    @Test
    func a_view_that_never_held_the_drag_changes_nothing() async {
        let presence = PinDragPresence()
        presence.set(.rows, holds: false)
        #expect(!presence.isActive)
        presence.set(.strip, holds: true)
        presence.set(.rows, holds: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(presence.isActive)
    }

    @Test
    func a_drop_clears_every_holder_at_once() async {
        let presence = PinDragPresence()
        presence.set(.header(UUID()), holds: true)
        presence.set(.rows, holds: true)
        presence.reset()
        #expect(!presence.isActive)
        // The header never let go, but it does not keep the next drag open.
        presence.set(.strip, holds: true)
        presence.set(.strip, holds: false)
        #expect(await poll { presence.isActive ? nil : true } == true)
    }

    @Test
    func the_band_shows_during_a_drag_only_when_no_tab_is_pinned() {
        typealias Zone = PinTabDropZone
        #expect(Zone.isBandVisible(showsBand: true, isDragOnSidebar: true, isTargeted: false))
        #expect(Zone.isBandVisible(showsBand: true, isDragOnSidebar: false, isTargeted: true))
        #expect(!Zone.isBandVisible(showsBand: true, isDragOnSidebar: false, isTargeted: false))
        #expect(!Zone.isBandVisible(showsBand: false, isDragOnSidebar: true, isTargeted: true))
    }

    @Test
    func only_a_tab_or_a_pane_can_pin() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        try pasteboard.setData(
            JSONEncoder().encode(MovableTab(tabID: UUID(), sourceProjectID: UUID())),
            forType: NSPasteboard.PasteboardType(UTType.mactermTab.identifier)
        )
        #expect(PinDragPresence.isPinnable(pasteboard))

        pasteboard.clearContents()
        pasteboard.setData(MovablePane.payload(for: UUID()), forType: .mactermPaneID)
        #expect(PinDragPresence.isPinnable(pasteboard))

        pasteboard.clearContents()
        try pasteboard.setData(
            JSONEncoder().encode(MovableProject(projectID: UUID())),
            forType: NSPasteboard.PasteboardType(UTType.mactermProject.identifier)
        )
        #expect(!PinDragPresence.isPinnable(pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("/tmp", forType: .string)
        #expect(!PinDragPresence.isPinnable(pasteboard))
    }

    /// Polls until `read` gives a value, sleeping between tries, for up to
    /// two seconds.
    private func poll<Value>(_ read: () -> Value?) async -> Value? {
        for _ in 0 ..< 100 {
            if let value = read() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
