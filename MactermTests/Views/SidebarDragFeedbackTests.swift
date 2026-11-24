import AppKit
@testable import Macterm
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
struct SidebarDragFeedbackTests {
    /// Two sidebar Lists in one window, as the native sidebar and the overlay
    /// sidebar are. Only the List with the probe gets the gap. The other List
    /// keeps the default insertion line.
    @Test
    func only_the_list_with_the_probe_gets_the_gap_feedback() async throws {
        let content = HStack(spacing: 0) {
            sidebarList().background { SidebarDragFeedback(isGuarded: .constant(false)) }
            sidebarList()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        let outlines = try #require(await poll {
            let found = Self.outlines(in: window.contentView!)
            return found.count == 2 ? found : nil
        })
        let sorted = outlines.sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        let probed = await poll { sorted[0].draggingDestinationFeedbackStyle == .gap ? true : nil }
        #expect(probed == true)
        #expect(sorted[1].draggingDestinationFeedbackStyle == .sourceList)
    }

    @Test
    func a_frame_that_no_outline_covers_finds_nothing() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(SidebarDragFeedback.ProbeView.outline(at: NSRect(x: 0, y: 0, width: 50, height: 50), in: root) == nil)
        #expect(SidebarDragFeedback.ProbeView.outline(at: .zero, in: root) == nil)
    }

    /// A drag across a section, out of the outline view (as onto a project
    /// header with its own drop destination), back in, and a drop. Without
    /// `OutlineGapDropGuard`, the exit crashes the test process in SwiftUI.
    @Test
    func a_drag_that_leaves_the_gap_outline_and_comes_back_drops_at_its_slot() async throws {
        let drops = DropLog()
        let content = List {
            ForEach(["A", "B"], id: \.self) { key in
                DisclosureGroup(isExpanded: .constant(true)) {
                    ForEach(["\(key)0", "\(key)1"], id: \.self) { Text($0) }
                        .dropDestination(for: String.self) { items, offset in
                            drops.entries.append("\(key) \(items) \(offset)")
                        }
                } label: {
                    Text(key).dropDestination(for: String.self) { _, _ in true }
                }
            }
        }
        .listStyle(.sidebar)
        .background { SidebarDragFeedback(isGuarded: .constant(false)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        let outline = try #require(await poll {
            window.contentView.flatMap { Self.outlines(in: $0).first }.flatMap {
                $0.draggingDestinationFeedbackStyle == .gap && $0.numberOfRows == 6 ? $0 : nil
            }
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("A1", forType: .string)
        func point(row: Int, fraction: CGFloat) -> NSPoint {
            let rect = outline.rect(ofRow: row)
            return outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
        }
        let drag = FakeDrag(location: point(row: 1, fraction: 0.2), pasteboard: pasteboard, window: window)

        #expect(!outline.draggingEntered(drag).isEmpty)
        // Into the rows of section B (rows: A, A0, A1, B, B0, B1).
        drag.location = point(row: 4, fraction: 0.8)
        #expect(!outline.draggingUpdated(drag).isEmpty)
        outline.draggingExited(drag)
        #expect(drops.entries.isEmpty)
        // Back in, above A1, and drop.
        drag.location = point(row: 2, fraction: 0.2)
        #expect(!outline.draggingEntered(drag).isEmpty)
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)

        let log = await poll { drops.entries.isEmpty ? nil : drops.entries }
        #expect(log == ["A [\"A1\"] 1"])
    }

    /// A project drag opens its gap at the project slot nearest to the
    /// pointer, and the drop lands at that slot (ui-review 0585: the gap
    /// stayed at the start slot, and the drop went somewhere else). The rows:
    /// A (A0, A1), B (B0, B.x (Bx0), B.y), C, and a scratch row S0, as the
    /// sidebar has them. The test calls the outline view, so the header rows
    /// do not take the drag here as their own drop views do in the app.
    @Test
    func a_project_drag_drops_at_the_slot_of_its_gap() async throws {
        let drops = DropLog()
        let tree = [
            ProbeNode(name: "A", tabs: ["A0", "A1"], children: []),
            ProbeNode(name: "B", tabs: ["B0"], children: [
                ProbeNode(name: "B.x", tabs: ["Bx0"], children: []),
                ProbeNode(name: "B.y", tabs: [], children: []),
            ]),
            ProbeNode(name: "C", tabs: [], children: []),
        ]
        let projectType = NSPasteboard.PasteboardType(UTType.mactermProject.identifier)
        let content = List {
            ForEach(tree) { ProbeProjectRow(node: $0, drops: drops) }
                .dropDestination(for: MovableProject.self) { _, offset in
                    drops.entries.append("top \(offset)")
                }
            ForEach(["S0"], id: \.self) { Text($0) }
                .dropDestination(for: MovableTab.self) { _, offset in
                    drops.entries.append("scratch \(offset)")
                }
        }
        .listStyle(.sidebar)
        .background { SidebarDragFeedback(branchTypes: [projectType], isGuarded: .constant(false)) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.layoutIfNeeded()

        // Rows: 0 A, 1 A0, 2 A1, 3 B, 4 B0, 5 B.x, 6 Bx0, 7 B.y, 8 C, 9 S0.
        let outline = try #require(await poll {
            window.contentView.flatMap { Self.outlines(in: $0).first }.flatMap {
                $0.draggingDestinationFeedbackStyle == .gap && $0.numberOfRows == 10 ? $0 : nil
            }
        })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try pasteboard.setData(JSONEncoder().encode(MovableProject(projectID: UUID())), forType: projectType)

        func drop(row: Int, fraction: CGFloat) async -> [String] {
            drops.entries = []
            let rect = outline.rect(ofRow: row)
            let location = outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
            let drag = FakeDrag(location: location, pasteboard: pasteboard, window: window)
            _ = outline.draggingEntered(drag)
            _ = outline.draggingUpdated(drag)
            guard outline.prepareForDragOperation(drag), outline.performDragOperation(drag) else {
                outline.draggingExited(drag)
                return []
            }
            outline.concludeDragOperation(drag)
            return await poll { drops.entries.isEmpty ? nil : drops.entries } ?? []
        }

        // On A's tabs (A has no projects inside): after A.
        #expect(await drop(row: 2, fraction: 0.5) == ["top 1"])
        // On the upper half of B's row: before B, the same slot.
        #expect(await drop(row: 3, fraction: 0.1) == ["top 1"])
        // On B's tab: inside B, before its first project.
        #expect(await drop(row: 4, fraction: 0.5) == ["into B 0"])
        // On the tab of B.x: after B.x, inside B.
        #expect(await drop(row: 6, fraction: 0.5) == ["into B 1"])
        // On the upper half of C's row: before C.
        #expect(await drop(row: 8, fraction: 0.1) == ["top 2"])
        // Below C, the scratch rows own the slot: no drop, and no crash on
        // C or B.y, which have no rows.
        #expect(await drop(row: 8, fraction: 0.9).isEmpty)
        #expect(await drop(row: 7, fraction: 0.9) == ["into B 2"])
    }

    private func sidebarList() -> some View {
        List {
            Section {
                ForEach(0 ..< 3, id: \.self) { Text("row \($0)") }
            }
        }
        .listStyle(.sidebar)
    }

    private static func outlines(in view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap { outlines(in: $0) }
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

private struct ProbeNode: Identifiable {
    let name: String
    let tabs: [String]
    let children: [ProbeNode]
    var id: String { name }
}

/// A project row of the sidebar's shape: its tabs, then the projects inside
/// it. Only a `ForEach` with rows has a drop destination, as in the app.
private struct ProbeProjectRow: View {
    let node: ProbeNode
    let drops: DropLog

    var body: some View {
        DisclosureGroup(isExpanded: .constant(true)) {
            if node.tabs.isEmpty {
                ForEach(node.tabs, id: \.self) { Text($0) }
            } else {
                ForEach(node.tabs, id: \.self) { Text($0) }
                    .dropDestination(for: MovableTab.self) { _, offset in
                        drops.entries.append("tab \(node.name) \(offset)")
                    }
            }
            if node.children.isEmpty {
                ForEach(node.children) { ProbeProjectRow(node: $0, drops: drops) }
            } else {
                ForEach(node.children) { ProbeProjectRow(node: $0, drops: drops) }
                    .dropDestination(for: MovableProject.self) { _, offset in
                        drops.entries.append("into \(node.name) \(offset)")
                    }
            }
        } label: {
            Text(node.name)
        }
    }
}

@MainActor
private final class DropLog {
    var entries: [String] = []
}

/// A drag that the test moves by hand. AppKit reads only the location, the
/// pasteboard, the window and the operation mask from it here.
private final class FakeDrag: NSObject, NSDraggingInfo {
    var location: NSPoint
    let pasteboard: NSPasteboard
    weak var window: NSWindow?

    init(location: NSPoint, pasteboard: NSPasteboard, window: NSWindow) {
        self.location = location
        self.pasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions = [],
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
